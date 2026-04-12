#!/usr/bin/env bash
# Forensic Workflow Walker: Enhanced Edition
# Traverses git history and verifies existences of images via native Docker manifest inspection.

set -eo pipefail

IMAGES_MAPPING="${INPUT_IMAGES:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
DEBUG="${INPUT_DEBUG:-false}"
GH_TOKEN="${GH_TOKEN:-}"
DIR="${INPUT_DIR:-.}"

cd "$DIR" || { echo "::error::Could not change to directory $DIR"; exit 1; }

if [[ -z "$IMAGES_MAPPING" ]]; then
  echo "::error::No image mapping provided. Format: component1=repo/image1 component2=repo/image2"
  exit 1
fi

# Pre-flight Checks (Forensic Safeguards)
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "::error::Workflow Walker requires a git repository. Please ensure 'actions/checkout' was called before this action."
  exit 1
fi

if ! docker version > /dev/null 2>&1; then
  echo "::error ::Workflow Walker requires Docker. Please ensure Docker is installed and functional on the runner."
  exit 1
fi

echo "Group: Workflow Walker — Forensic History Traversal"

# Parse mapping into an associative array
declare -A IMAGE_REPOS
for pair in $IMAGES_MAPPING; do
    component="${pair%%=*}"
    repo="${pair#*=}"
    IMAGE_REPOS["$component"]="$repo"
done

# Resolve the list of SHAs to check (Graph-aware)
# We limit to MAX_DEPTH to avoid walking the entire history of time
echo "  Max Depth: $MAX_DEPTH"
REVISIONS=$(git rev-list --max-count="$MAX_DEPTH" HEAD 2>/dev/null || true)

if [[ -z "$REVISIONS" ]]; then
    # Fallback for extremely shallow clones or empty repos
    echo "  [!] Warning: git rev-list failed. Falling back to HEAD only."
    REVISIONS=$(git rev-parse HEAD)
fi

# Tracking state
FOUND_BUNDLE_JSON="{}"
NOT_FOUND_COMPONENTS=("${!IMAGE_REPOS[@]}")

check_image() {
    local component="$1"
    local sha="$2"
    local source_desc="$3"
    local repo="${IMAGE_REPOS[$component]}"
    local full_image="${repo}:sha-${sha}"

    if docker manifest inspect "$full_image" > /dev/null 2>&1; then
        echo "  [✓] FOUND ($source_desc): $component -> $sha"
        # Update the JSON bundle using jq
        FOUND_BUNDLE_JSON=$(echo "$FOUND_BUNDLE_JSON" | jq --arg c "$component" --arg s "$sha" '.[$c] = $s')
        return 0
    fi
    return 1
}

# Main Traversal Loop
for TARGET_SHA in $REVISIONS; do
    [[ "$DEBUG" == "true" ]] && echo "  🔍 Inspecting $TARGET_SHA..."

    # Secure PR lookup: Query GitHub API for the PR associated with this commit SHA.
    # This correctly handles squash-merges by finding the original head SHA without
    # relying on easily-spoofable commit message metadata.
    if [[ -n "$GH_TOKEN" ]]; then
        PR_JSON=$(gh api "repos/${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}/commits/${TARGET_SHA}/pulls" 2>/dev/null || true)
        PR_HEAD_SHA=$(echo "$PR_JSON" | jq -r '.[0].head.sha' 2>/dev/null || echo "null")
        
        if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "null" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
            REMAINING_COMPONENTS=()
            for component in "${NOT_FOUND_COMPONENTS[@]}"; do
                if check_image "$component" "$PR_HEAD_SHA" "via PR Link"; then
                    continue
                fi
                REMAINING_COMPONENTS+=("$component")
            done
            NOT_FOUND_COMPONENTS=("${REMAINING_COMPONENTS[@]}")
        fi
    fi

    # 2. Main-step: Check the commit SHA itself
    if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
        REMAINING_COMPONENTS=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            if check_image "$component" "$TARGET_SHA" "Direct SHA"; then
                continue
            fi
            REMAINING_COMPONENTS+=("$component")
        done
        NOT_FOUND_COMPONENTS=("${REMAINING_COMPONENTS[@]}")
    fi

    # Exit early if everything is found
    if [[ ${#NOT_FOUND_COMPONENTS[@]} -eq 0 ]]; then
        echo "  [!] All components resolved successfully."
        break
    fi
done

if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
    echo "::warning::Could not find manifests for all components after inspecting $MAX_DEPTH commits."
    echo "  MISSING: ${NOT_FOUND_COMPONENTS[*]}"
fi

echo "::endgroup::"

# Output the result
{
  echo "bundle=${FOUND_BUNDLE_JSON}"
} >> "$GITHUB_OUTPUT"
