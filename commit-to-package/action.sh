#!/usr/bin/env bash
# Forensic Workflow Walker: Professional Edition
# Traverses git history and resolves image SHAs via secure GitHub API PR mapping.

set -eo pipefail

# Mandatory inputs
IMAGES_MAPPING="${INPUT_IMAGES:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
GH_TOKEN="${GH_TOKEN:-}"
DIR="${INPUT_DIR:-.}"
REPOSITORY="${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}"

if [[ -z "$IMAGES_MAPPING" ]]; then
  echo "::error::No image mapping provided. Format: component1=repo/image1 component2=repo/image2"
  exit 1
fi

# Pre-flight setup
cd "$DIR" || { echo "::error::Could not change to directory $DIR"; exit 1; }

# Parse mapping into associative array
declare -A IMAGE_REPOS
for pair in $IMAGES_MAPPING; do
    component="${pair%%=*}"
    repo="${pair#*=}"
    IMAGE_REPOS["$component"]="$repo"
done

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
    local full_image="${repo}:sha-${sha}"

    if docker manifest inspect "$full_image" > /dev/null 2>&1; then
        echo "  [✓] FOUND ($desc): $component -> $sha"
        FOUND_BUNDLE_JSON=$(echo "$FOUND_BUNDLE_JSON" | jq --arg c "$component" --arg s "$sha" '.[$c] = $s')
        return 0
    fi
    return 1
}

# Principal Traversal Loop
for TARGET_SHA in $REVISIONS; do
    # 1. Resolve associated PR Head SHA (the built SHA for Squash Merges)
    if [[ -n "$GH_TOKEN" ]]; then
        # Endpoint mirrors the exact working pattern from your Vexilon script
        PR_HEAD_SHA=$(gh api "/repos/${REPOSITORY}/commits/${TARGET_SHA}/pulls" --jq '.[0].head.sha' 2>/dev/null || true)
        
        if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "null" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
            REFRESHED_COMPONENTS=()
            for component in "${NOT_FOUND_COMPONENTS[@]}"; do
                if ! check_image "$component" "$PR_HEAD_SHA" "PR Head"; then
                    REFRESHED_COMPONENTS+=("$component")
                fi
            done
            NOT_FOUND_COMPONENTS=("${REFRESHED_COMPONENTS[@]}")
        fi
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
