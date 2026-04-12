#!/usr/bin/env bash
# Forensic Workflow Walker: Native Edition
# Traverses git history and verifies existences of images via native Docker manifest inspection.

set -eo pipefail

# ShellCheck global ignores for GitHub Actions
# shellcheck disable=SC2154
# shellcheck disable=SC2129

IMAGES_MAPPING="${INPUT_IMAGES:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
DEBUG="${INPUT_DEBUG:-false}"

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
  echo "::error::Workflow Walker requires Docker. Please ensure Docker is installed and functional on the runner."
  exit 1
fi

echo "Group: Workflow Walker — Forensic History Traversal"

# Parse the mapping into an associative array (requires Bash 4+)
declare -A IMAGE_REPOS
for pair in $IMAGES_MAPPING; do
    component="${pair%%=*}"
    repo="${pair#*=}"
    IMAGE_REPOS["$component"]="$repo"
done

# Traverse history
CURRENT_DEPTH=0
FOUND_BUNDLE=""
NOT_FOUND_COMPONENTS=("${!IMAGE_REPOS[@]}")

# Log base/head context
echo "  Head Ref: ${INPUT_HEAD_REF:-HEAD}"
echo "  Max Depth: $MAX_DEPTH"

while [[ $CURRENT_DEPTH -lt $MAX_DEPTH ]] && [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; do
    TARGET_SHA=$(git rev-parse "HEAD~$CURRENT_DEPTH")
    
    [[ "$DEBUG" == "true" ]] && echo "  Checking depth $CURRENT_DEPTH (SHA: $TARGET_SHA)..."

    # Secure PR lookup: Query GitHub API for the PR associated with this commit SHA.
    # This correctly handles squash-merges by finding the original head SHA without
    # relying on easily-spoofable commit message metadata.
    if [[ -n "$GH_TOKEN" ]]; then
        PR_HEAD_SHA=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${TARGET_SHA}/pulls" --jq '.[0].head.sha' 2>/dev/null || true)
        
        if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
            [[ "$DEBUG" == "true" ]] && echo "    [!] Detected associated PR. Resolving head SHA -> $PR_HEAD_SHA"
            
            # Check PR Head SHA for each missing component
            for component in "${NOT_FOUND_COMPONENTS[@]}"; do
                FULL_IMAGE="${IMAGE_REPOS[$component]}:$PR_HEAD_SHA"
                if docker manifest inspect "$FULL_IMAGE" > /dev/null 2>&1; then
                    echo "  [✓] FOUND (via PR Link): $component -> $PR_HEAD_SHA"
                    FOUND_BUNDLE="${FOUND_BUNDLE}${component}=${PR_HEAD_SHA} "
                    
                    # Update NOT_FOUND_COMPONENTS (filter out found one)
                    NEW_NOT_FOUND=()
                    for c in "${NOT_FOUND_COMPONENTS[@]}"; do
                        [[ "$c" != "$component" ]] && NEW_NOT_FOUND+=("$c")
                    done
                    NOT_FOUND_COMPONENTS=("${NEW_NOT_FOUND[@]}")
                fi
            done
        fi
    fi

    REMAINING_COMPONENTS=()
    for component in "${NOT_FOUND_COMPONENTS[@]}"; do
        FULL_IMAGE="${IMAGE_REPOS[$component]}:$TARGET_SHA"
        
        # Native Docker Check (No Crane!)
        if docker manifest inspect "$FULL_IMAGE" > /dev/null 2>&1; then
            echo "  [✓] FOUND: $component -> $TARGET_SHA"
            FOUND_BUNDLE="${FOUND_BUNDLE}${component}=${TARGET_SHA} "
        else
            REMAINING_COMPONENTS+=("$component")
        fi
    done
    
    NOT_FOUND_COMPONENTS=("${REMAINING_COMPONENTS[@]}")
    ((CURRENT_DEPTH++))
done

if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
    echo "::warning::Could not find manifests for all components after $MAX_DEPTH commits."
    echo "  MISSING: ${NOT_FOUND_COMPONENTS[*]}"
fi

echo "::endgroup::"

# Building the JSON object using native Bash strings (Zero dependencies!)
FOUND_JSON="{"
for component in "${!IMAGE_REPOS[@]}"; do
    # Check if we actually found a SHA for this component
    for found in $FOUND_BUNDLE; do
        if [[ "$found" == "$component="* ]]; then
            sha="${found#*=}"
            FOUND_JSON="${FOUND_JSON}\"$component\": \"$sha\", "
            break
        fi
    done
done

# Trim trailing comma and close JSON
FOUND_JSON="${FOUND_JSON%, }}"
echo "::endgroup::"

# Output the result
{
  echo "bundle=${FOUND_JSON:-{}}"
} >> "$GITHUB_OUTPUT"
