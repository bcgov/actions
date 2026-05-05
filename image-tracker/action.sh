#!/bin/bash
# Image Tracker — Forensic History Traversal (Minimalist Version)
# Resolves images tagged with the metadata-action default (sha-<short-sha>)
set -e

DIR="${INPUT_DIR:-.}"
REPOSITORY="${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}"
PACKAGE_INPUT="${INPUT_PACKAGE:-}"
MAX_DEPTH="${INPUT_INVENTORY_DEPTH:-${INPUT_MAX_DEPTH:-100}}"
TARGET_REV="${INPUT_TARGET_REVISION:-HEAD}"

# Map packages to GHCR paths
declare -A IMAGE_REPOS
if [[ -n "$PACKAGE_INPUT" ]]; then
    repo_name="${REPOSITORY#*/}"
    lc_repo=$(echo "$REPOSITORY" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | tr -d '[:space:]')
        [[ -z "$pkg" ]] && continue
        if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
            IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}"
        else
            IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}/${pkg,,}"
        fi
    done < <(echo "$PACKAGE_INPUT" | tr ',' '\n')
fi

# Internal State
FOUND_BUNDLE_FILE=$(mktemp)
RESOLVED_PR="null"

# Helper: Check one vanilla tag (sha-<short-sha>)
check_image() {
    local component="$1"
    local sha="${2:0:7}"
    local desc="$3"
    local tag="${IMAGE_REPOS[$component]}:sha-${sha}"

    if docker manifest inspect "$tag" > /dev/null 2>&1; then
        echo "  [✓] FOUND: $component -> $tag ($desc)"
        echo "${component}=sha-${sha}" >> "$FOUND_BUNDLE_FILE"
        return 0
    fi
    return 1
}

echo "Image Tracker — Vanilla History Traversal"
echo "  Target: $REPOSITORY @ $TARGET_REV"
echo "  Pattern: sha-<short-sha> (metadata-action default)"

# Forensic Setup
cd "$DIR"
git fetch --quiet --deepen="$MAX_DEPTH" origin "$TARGET_REV" 2>/dev/null || true

# Fetch PR mappings for the traversal
PR_MAP_JSON=$(gh api -H "Accept: application/vnd.github+json" \
    "/repos/${REPOSITORY}/pulls?state=all&per_page=100" \
    --jq '[.[] | {number: .number, head: .head.sha, merge: .merge_commit_sha}]')

# Traversal Loop
REVISIONS=$(git rev-list --max-count="$MAX_DEPTH" "$TARGET_REV")
for TARGET_SHA in $REVISIONS; do
    # 1. Is this SHA linked to a PR?
    PR_DATA=$(echo "$PR_MAP_JSON" | jq -c ".[] | select(.merge == \"$TARGET_SHA\" or .head == \"$TARGET_SHA\")" | head -n 1)
    
    if [[ -n "$PR_DATA" ]]; then
        PR_NUM=$(echo "$PR_DATA" | jq -r '.number')
        HEAD_SHA=$(echo "$PR_DATA" | jq -r '.head')
        
        # We check the Head SHA first (the developer's work)
        ALL_FOUND="true"
        for component in "${!IMAGE_REPOS[@]}"; do
            if ! grep -q "^${component}=" "$FOUND_BUNDLE_FILE"; then
                if ! check_image "$component" "$HEAD_SHA" "PR #$PR_NUM"; then
                    ALL_FOUND="false"
                fi
            fi
        done
        
        [[ "$RESOLVED_PR" == "null" ]] && RESOLVED_PR="$PR_NUM"
        [[ "$ALL_FOUND" == "true" && ${#IMAGE_REPOS[@]} -gt 0 ]] && break
    fi

    # 2. Check the commit itself (fallback for non-PR or direct pushes)
    ALL_FOUND="true"
    for component in "${!IMAGE_REPOS[@]}"; do
        if ! grep -q "^${component}=" "$FOUND_BUNDLE_FILE"; then
            if ! check_image "$component" "$TARGET_SHA" "Commit"; then
                ALL_FOUND="false"
            fi
        fi
    done
    [[ "$ALL_FOUND" == "true" && ${#IMAGE_REPOS[@]} -gt 0 ]] && break
done

# Output Generation
FOUND_BUNDLE_JSON="{"
while IFS='=' read -r component sha; do
    FOUND_BUNDLE_JSON="${FOUND_BUNDLE_JSON}\"$component\": \"$sha\", "
    [[ -z "$FIRST_TAG" ]] && FIRST_TAG="$sha"
done < "$FOUND_BUNDLE_FILE"
FOUND_BUNDLE_JSON="${FOUND_BUNDLE_JSON%, }""}"
[[ "$FOUND_BUNDLE_JSON" == "{" ]] && FOUND_BUNDLE_JSON="{}"

{
    echo "packages=${FOUND_BUNDLE_JSON}"
    echo "bundle=${FOUND_BUNDLE_JSON}"
    echo "pr=${RESOLVED_PR}"
    echo "tag=${FIRST_TAG:-null}"
} >> "$GITHUB_OUTPUT"

echo ""
echo "Resolution Complete:"
echo "  PR: #$RESOLVED_PR"
echo "  Tag: ${FIRST_TAG:-None found}"
