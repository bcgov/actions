#!/usr/bin/env bash
# Forensic Workflow Walker
# Traverses git history and resolves image SHAs via secure GitHub API PR mapping.

set -eo pipefail

# Inputs
PACKAGE_INPUT="${INPUT_PACKAGE:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
GH_TOKEN="${GH_TOKEN:-}"
DIR="${INPUT_DIR:-.}"
REPOSITORY="${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}"
REVISION="${INPUT_REF:-HEAD}"

if [[ -z "$PACKAGE_INPUT" ]]; then
  echo "::error::No packages provided. Set the 'package' input."
  exit 1
fi

cd "$DIR" || { echo "::error::Could not change to directory $DIR"; exit 1; }

# Parse one or more package names (space, comma, or newline separated)
# and resolve each to its GHCR image path.
declare -A IMAGE_REPOS
repo_name="${REPOSITORY#*/}"
lc_repo=$(echo "$REPOSITORY" | tr '[:upper:]' '[:lower:]')

while IFS= read -r pkg; do
    pkg=$(echo "$pkg" | tr -d '[:space:]')
    [[ -z "$pkg" ]] && continue
    # If the package name matches the repo name, image lives at the repo root path
    if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
        IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}"
    else
        IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}/${pkg,,}"
    fi
done < <(echo "$PACKAGE_INPUT" | tr ',' '\n')

echo "::group::Workflow Walker — Forensic History Traversal"
echo "  Target Repository: $REPOSITORY"
echo "  Starting Revision: $REVISION"
echo "  Max Depth: $MAX_DEPTH"
echo "  Packages: ${!IMAGE_REPOS[*]}"
echo ""

# Resolve starting commit (support Tags/Branches/SHAs)
START_SHA=$(git rev-parse --verify --quiet "${REVISION}^{commit}" 2>/dev/null || true)
if [[ -z "$START_SHA" ]]; then
    # Fallback: if we can't find the commit, try original HEAD for safety
    START_SHA=$(git rev-parse --verify --quiet "HEAD^{commit}")
    echo "  [!] Warning: Revision '$REVISION' not found. Defaulting to HEAD."
fi

REVISIONS=$(git rev-list --max-count="$MAX_DEPTH" "$START_SHA" 2>/dev/null || true)
if [[ -z "$REVISIONS" ]]; then
    # Final fallback: just the single SHA
    REVISIONS="$START_SHA"
fi

# Verification state
FOUND_PACKAGES_JSON="{}"
NOT_FOUND_COMPONENTS=("${!IMAGE_REPOS[@]}")

check_image() {
    local component="$1"
    local sha="$2"
    local desc="$3"
    local full_image="${IMAGE_REPOS[$component]}:sha-${sha}"

    if docker manifest inspect "$full_image" > /dev/null 2>&1; then
        echo "  [✓] FOUND ($desc): $component -> sha-${sha}"
        FOUND_PACKAGES_JSON=$(echo "$FOUND_PACKAGES_JSON" | jq -c --arg c "$component" --arg s "sha-${sha}" '.[$c] = $s')
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
        echo "  [!] Success: All packages resolved."
        break
    fi
done

echo "::endgroup::"

if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
    echo "::error::Failed to resolve packages after $MAX_DEPTH commits: ${NOT_FOUND_COMPONENTS[*]}"
    exit 1
fi

echo "packages=${FOUND_PACKAGES_JSON}" >> "$GITHUB_OUTPUT"
