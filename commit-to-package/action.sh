#!/usr/bin/env bash
# Forensic Workflow Walker: Professional Edition
# Traverses git history and resolves image SHAs via secure GitHub API PR mapping.

set -eo pipefail

# Mandatory inputs (at least one of package or images)
PACKAGE_NAMES="${INPUT_PACKAGE:-}"
IMAGES_MAPPING="${INPUT_IMAGES:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
GH_TOKEN="${GH_TOKEN:-}"
DIR="${INPUT_DIR:-.}"
REPOSITORY="${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}"

if [[ -z "$PACKAGE_NAMES" && -z "$IMAGES_MAPPING" ]]; then
  echo "::error::No package or image mapping provided. Provide 'package' or 'images' input."
  exit 1
fi

# Pre-flight setup
cd "$DIR" || { echo "::error::Could not change to directory $DIR"; exit 1; }

# Unified mapping logic
declare -A IMAGE_REPOS

# 1. Process explicit images mapping
if [[ -n "$IMAGES_MAPPING" ]]; then
    for pair in $IMAGES_MAPPING; do
        component="${pair%%=*}"
        repo="${pair#*=}"
        IMAGE_REPOS["$component"]="$repo"
    done
fi

# 2. Process package names (with auto-resolution)
# Explicit images mapping takes precedence — only auto-resolve entries not already set.
if [[ -n "$PACKAGE_NAMES" ]]; then
    # Support space or comma separated lists
    CLEAN_PACKAGES=$(echo "$PACKAGE_NAMES" | tr ',' ' ')
    repo_name="${REPOSITORY#*/}"
    lc_repo=$(echo "$REPOSITORY" | tr '[:upper:]' '[:lower:]')
    for pkg in $CLEAN_PACKAGES; do
        # Skip if already set by explicit images mapping
        [[ -n "${IMAGE_REPOS[$pkg]+x}" ]] && continue
        # Heuristic: If package name matches repo name, use the repo base path
        if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
             IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}"
        else
             IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}/${pkg,,}"
        fi
    done
fi

echo "Group: Workflow Walker — Forensic History Traversal"
echo "  Target Repository: $REPOSITORY"
echo "  Max Depth: $MAX_DEPTH"

# Resolve revisions (Graph-aware)
REVISIONS=$(git rev-list --max-count="$MAX_DEPTH" HEAD 2>/dev/null || true)
if [[ -z "$REVISIONS" ]]; then
    # Fallback to local HEAD (last resort)
    REVISIONS=$(git rev-parse HEAD)
fi

# Image verification state
FOUND_BUNDLE_JSON="{}"
NOT_FOUND_COMPONENTS=("${!IMAGE_REPOS[@]}")

# Helper: Verify if image exists in GHCR
check_image() {
    local component="$1"
    local sha="$2"
    local desc="$3"
    local repo="${IMAGE_REPOS[$component]}"
    local full_image

    # If the repo already contains a tag or digest, treat it as a literal reference
    if [[ "$repo" == *":"* || "$repo" == *"@"* ]]; then
        full_image="$repo"
    else
        full_image="${repo}:sha-${sha}"
    fi

    if docker manifest inspect "$full_image" > /dev/null 2>&1; then
        echo "  [✓] FOUND ($desc): $component -> ${full_image#*[:@]}"
        # Ensure we return the full tag (sha-...) or digest (sha256:...)
        local result="${full_image#*[:@]}"
        # If it was a digest, we need to restore the prefix (docker doesn't return it in #)
        [[ "$full_image" == *"@"* ]] && result="sha256:$result"
        
        FOUND_BUNDLE_JSON=$(echo "$FOUND_BUNDLE_JSON" | jq -c --arg c "$component" --arg s "$result" '.[$c] = $s')
        return 0
    fi
    return 1
}

# Phase 0: Literal Resolution (Check for explicit tags/digests first)
echo "Phase 0: Literal Resolution"
REFRESHED_COMPONENTS=()
for component in "${NOT_FOUND_COMPONENTS[@]}"; do
    repo="${IMAGE_REPOS[$component]}"
    if [[ "$repo" == *":"* || "$repo" == *"@"* ]]; then
        if check_image "$component" "" "Literal"; then
            continue
        fi
    fi
    REFRESHED_COMPONENTS+=("$component")
done
NOT_FOUND_COMPONENTS=("${REFRESHED_COMPONENTS[@]}")

# Early exit if all literally resolved
if [[ ${#NOT_FOUND_COMPONENTS[@]} -eq 0 ]]; then
    echo "  [!] Success: All components resolved via literal mapping."
else
    echo "Group: Workflow Walker — Forensic History Traversal"
    echo "  Target Repository: $REPOSITORY"
    echo "  Max Depth: $MAX_DEPTH"
fi

# Gather all PR mappings once (Performance: Bulk lookup instead of per-commit API calls)
declare -A PR_MAP
if [[ -n "$GH_TOKEN" ]]; then
    echo "  [i] Batch-fetching PR data for $REPOSITORY..."
    # Fetches recent PRs and maps merge commit -> head sha for squash/merge resolution
    while IFS= read -r row; do
        merge_sha=$(echo "$row" | cut -f1)
        head_sha=$(echo "$row" | cut -f2)
        if [[ -n "$merge_sha" && "$merge_sha" != "null" ]]; then
            PR_MAP["$merge_sha"]="$head_sha"
        fi
    done < <(gh api "/repos/${REPOSITORY}/pulls?state=closed&per_page=100" --jq '.[] | [.merge_commit_sha, .head.sha] | @tsv' 2>/dev/null || true)
fi

# Principal Traversal Loop
for TARGET_SHA in $REVISIONS; do
    # 1. Resolve associated PR Head SHA (the built SHA for Squash Merges) via local map
    PR_HEAD_SHA="${PR_MAP[$TARGET_SHA]:-}"
    
    if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "null" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
        REFRESHED_COMPONENTS=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            if ! check_image "$component" "$PR_HEAD_SHA" "PR Head"; then
                REFRESHED_COMPONENTS+=("$component")
            fi
        done
        NOT_FOUND_COMPONENTS=("${REFRESHED_COMPONENTS[@]}")
    fi

    # 2. Check the commit itself (Standard Merges / Directly built commits)
    if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
        REFRESHED_COMPONENTS=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            if ! check_image "$component" "$TARGET_SHA" "Commit SHA"; then
                REFRESHED_COMPONENTS+=("$component")
            fi
        done
        NOT_FOUND_COMPONENTS=("${REFRESHED_COMPONENTS[@]}")
    fi

    # Early termination if all resolved
    if [[ ${#NOT_FOUND_COMPONENTS[@]} -eq 0 ]]; then
        echo "  [!] Success: All components resolved."
        break
    fi
done

echo "::endgroup::"

# Validation
if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
    echo "::error::History traversal failed to resolve some components after $MAX_DEPTH commits."
    echo "  NOT FOUND: ${NOT_FOUND_COMPONENTS[*]}"
    exit 1
fi

# Output results to GITHUB_OUTPUT
echo "bundle=${FOUND_BUNDLE_JSON}" >> "$GITHUB_OUTPUT"
