#!/usr/bin/env bash
# Forensic Workflow Walker
# Traverses git history and resolves image SHAs via secure GitHub API PR mapping.

set -eo pipefail

# Inputs
IMAGES_MAPPING="${INPUT_IMAGES:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
GH_TOKEN="${GH_TOKEN:-}"
DIR="${INPUT_DIR:-.}"
REPOSITORY="${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}"

if [[ -z "$IMAGES_MAPPING" ]]; then
  echo "::error::No images provided. Set the 'images' input with package names or component=repo mappings."
  exit 1
fi

# Pre-flight setup
cd "$DIR" || { echo "::error::Could not change to directory $DIR"; exit 1; }

# Parse images input into component -> repo mapping.
# Each token is either:
#   bare name:        "frontend"             -> auto-resolved to ghcr.io/<owner>/<repo>[/<name>]
#   explicit mapping: "frontend=ghcr.io/..."  -> used as-is
declare -A IMAGE_REPOS
repo_name="${REPOSITORY#*/}"
lc_repo=$(echo "$REPOSITORY" | tr '[:upper:]' '[:lower:]')

for pair in $IMAGES_MAPPING; do
    if [[ "$pair" == *"="* ]]; then
        component="${pair%%=*}"
        repo="${pair#*=}"
    else
        component="$pair"
        # If name matches repo name, image lives at the repo root path
        if [[ "${pair,,}" == "${repo_name,,}" ]]; then
            repo="ghcr.io/${lc_repo}"
        else
            repo="ghcr.io/${lc_repo}/${pair,,}"
        fi
    fi
    IMAGE_REPOS["$component"]="$repo"
done

echo "Group: Workflow Walker — Forensic History Traversal"
echo "  Target Repository: $REPOSITORY"
echo "  Max Depth: $MAX_DEPTH"

# Resolve revisions
REVISIONS=$(git rev-list --max-count="$MAX_DEPTH" HEAD 2>/dev/null || true)
if [[ -z "$REVISIONS" ]]; then
    REVISIONS=$(git rev-parse HEAD)
fi

# Verification state
FOUND_BUNDLE_JSON="{}"
NOT_FOUND_COMPONENTS=("${!IMAGE_REPOS[@]}")

# Verify a single image tag exists in the registry
check_image() {
    local component="$1"
    local sha="$2"
    local desc="$3"
    local repo="${IMAGE_REPOS[$component]}"
    local full_image="${repo}:sha-${sha}"

    if docker manifest inspect "$full_image" > /dev/null 2>&1; then
        echo "  [✓] FOUND ($desc): $component -> sha-${sha}"
        FOUND_BUNDLE_JSON=$(echo "$FOUND_BUNDLE_JSON" | jq -c --arg c "$component" --arg s "sha-${sha}" '.[$c] = $s')
        return 0
    fi
    return 1
}

# Batch-fetch closed PR data once: merge_commit_sha -> head_sha
# This replaces per-commit API calls (N calls -> 1 call)
declare -A PR_MAP
if [[ -n "$GH_TOKEN" ]]; then
    echo "  [i] Batch-fetching PR merge map for $REPOSITORY..."
    while IFS=$'\t' read -r merge_sha head_sha; do
        [[ -n "$merge_sha" && "$merge_sha" != "null" ]] && PR_MAP["$merge_sha"]="$head_sha"
    done < <(gh api "/repos/${REPOSITORY}/pulls?state=closed&per_page=100" \
        --jq '.[] | [.merge_commit_sha, .head.sha] | @tsv' 2>/dev/null || true)
fi

# Traversal loop: for each commit, check PR head SHA then commit SHA
for TARGET_SHA in $REVISIONS; do
    # 1. Check associated PR head SHA (covers squash merges)
    PR_HEAD_SHA="${PR_MAP[$TARGET_SHA]:-}"
    if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "null" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
        REFRESHED=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            check_image "$component" "$PR_HEAD_SHA" "PR Head" || REFRESHED+=("$component")
        done
        NOT_FOUND_COMPONENTS=("${REFRESHED[@]}")
    fi

    # 2. Check the commit SHA itself (covers standard merges)
    if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
        REFRESHED=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            check_image "$component" "$TARGET_SHA" "Commit SHA" || REFRESHED+=("$component")
        done
        NOT_FOUND_COMPONENTS=("${REFRESHED[@]}")
    fi

    if [[ ${#NOT_FOUND_COMPONENTS[@]} -eq 0 ]]; then
        echo "  [!] Success: All components resolved."
        break
    fi
done

echo "::endgroup::"

if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
    echo "::error::Failed to resolve components after $MAX_DEPTH commits: ${NOT_FOUND_COMPONENTS[*]}"
    exit 1
fi

echo "bundle=${FOUND_BUNDLE_JSON}" >> "$GITHUB_OUTPUT"
