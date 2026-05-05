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
REVISION="${INPUT_REVISION:-HEAD}"
if [[ -n "$INPUT_INVENTORY_DEPTH" ]]; then
    MAX_DEPTH="$INPUT_INVENTORY_DEPTH"
    INVENTORY_MODE="true"
else
    MAX_DEPTH="${INPUT_MAX_DEPTH:-100}"
    INVENTORY_MODE="false"
fi

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

# Ensure we have enough local history to walk back
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" == "true" ]]; then
    echo "  [i] Deepening git history (depth: $MAX_DEPTH) for $REVISION..."
    PRIMARY_REMOTE="$(git remote 2>/dev/null | head -n 1 || echo "origin")"
    
    # Try deepening the history first
    git fetch --deepen="$MAX_DEPTH" "$PRIMARY_REMOTE" 2>/dev/null || \
    git fetch --unshallow "$PRIMARY_REMOTE" 2>/dev/null || true
    
    # If the target revision is still not available locally, fetch that specific ref
    if ! git rev-parse --verify --quiet "${REVISION}^{commit}" >/dev/null 2>&1; then
        git fetch --depth="$MAX_DEPTH" "$PRIMARY_REMOTE" "$REVISION" 2>/dev/null || true
    fi
else
    echo "  [i] Repository is not shallow; skipping history fetch."
fi

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
FOUND_BUNDLE_JSON="{}"
INVENTORY_JSON="[]"
NOT_FOUND_COMPONENTS=("${!IMAGE_REPOS[@]}")

check_image() {
    local component="$1"
    local sha="$2"
    local desc="$3"
    local target_commit="$4"
    local full_image="${IMAGE_REPOS[$component]}:sha-${sha}"

    if docker manifest inspect "$full_image" > /dev/null 2>&1; then
        echo "  [✓] FOUND ($desc): $component -> sha-${sha}"
        
        # In inventory mode, we track EVERYTHING found
        if [[ "$INVENTORY_MODE" == "true" ]]; then
            local merge_date
            merge_date=$(git log -1 --format=%cI "$target_commit" 2>/dev/null || echo "unknown")
            local pr_num="${PR_NUM_MAP[$target_commit]:-N/A}"
            INVENTORY_JSON=$(echo "$INVENTORY_JSON" | jq -c --arg c "$component" --arg s "sha-${sha}" --arg d "$merge_date" --arg p "$pr_num" \
                '. += [{"package": $c, "tag": $s, "merged_at": $d, "pr": $p}]')
        fi

        FOUND_BUNDLE_JSON=$(echo "$FOUND_BUNDLE_JSON" | jq -c --arg c "$component" --arg s "sha-${sha}" '.[$c] = $s')
        return 0
    fi
    echo "  [x] MISSING ($desc): sha-${sha}"
    return 1
}

declare -A PR_MAP
declare -A PR_NUM_MAP
if [[ -n "$GH_TOKEN" ]]; then
    echo "  [i] Batch-fetching PR merge map for $REPOSITORY..."
    PR_DATA=$(gh api "/repos/${REPOSITORY}/pulls?state=all&per_page=100" \
        --jq '.[] | [.merge_commit_sha, .head.sha, .number] | @tsv' 2>/dev/null || true)
    
    if [[ -n "$PR_DATA" ]]; then
        while IFS=$'\t' read -r merge_sha head_sha pr_num; do
            [[ -n "$merge_sha" && "$merge_sha" != "null" ]] && PR_MAP["$merge_sha"]="$head_sha"
            [[ -n "$merge_sha" && "$merge_sha" != "null" ]] && PR_NUM_MAP["$merge_sha"]="$pr_num"
        done <<< "$PR_DATA"
        echo "  [i] Loaded ${#PR_MAP[@]} PR mappings (including open PRs)."
    else
        echo "  [!] Warning: Could not fetch PR mappings. Squash merges may not be resolvable."
    fi
fi

# Traversal loop: for each commit, check PR head SHA then commit SHA
ACTUAL_COMMIT_COUNT=0
for TARGET_SHA in $REVISIONS; do
    ACTUAL_COMMIT_COUNT=$((ACTUAL_COMMIT_COUNT + 1))
    # 1. Check associated PR head SHA (covers squash merges)
    PR_HEAD_SHA="${PR_MAP[$TARGET_SHA]:-}"
    PR_NUM="${PR_NUM_MAP[$TARGET_SHA]:-}"
    if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "null" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
        REFRESHED=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            check_image "$component" "$PR_HEAD_SHA" "PR #$PR_NUM Head" "$TARGET_SHA" || REFRESHED+=("$component")
        done
        # Only update NOT_FOUND if we aren't in inventory mode (in inventory mode, we keep searching)
        if [[ "$INVENTORY_MODE" != "true" ]]; then
            NOT_FOUND_COMPONENTS=("${REFRESHED[@]}")
        fi
    fi

    # 2. Check the commit SHA itself (covers standard merges)
    if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 || "$INVENTORY_MODE" == "true" ]]; then
        REFRESHED=()
        for component in "${NOT_FOUND_COMPONENTS[@]}"; do
            check_image "$component" "$TARGET_SHA" "Commit SHA" "$TARGET_SHA" || REFRESHED+=("$component")
        done
        if [[ "$INVENTORY_MODE" != "true" ]]; then
            NOT_FOUND_COMPONENTS=("${REFRESHED[@]}")
        fi
    fi

    if [[ "$INVENTORY_MODE" != "true" && ${#NOT_FOUND_COMPONENTS[@]} -eq 0 ]]; then
        echo "  [!] Success: All packages resolved."
        break
    fi
done

if [[ "$INVENTORY_MODE" == "true" ]]; then
    echo ""
    echo "  [i] Inventory Summary:"
    echo "$INVENTORY_JSON" | jq -r '["PACKAGE", "TAG", "PR", "MERGED_AT"], (.[] | [.package, .tag, .pr, .merged_at]) | @tsv' | column -t -s $'\t' || true
    echo ""
fi

echo "::endgroup::"

if [[ ${#NOT_FOUND_COMPONENTS[@]} -gt 0 ]]; then
    echo "::error::Failed to resolve packages after checking $ACTUAL_COMMIT_COUNT commit(s) (Max limit: $MAX_DEPTH): ${NOT_FOUND_COMPONENTS[*]}"
    exit 1
fi

echo "packages=${FOUND_BUNDLE_JSON}" >> "$GITHUB_OUTPUT"
echo "bundle=${FOUND_BUNDLE_JSON}" >> "$GITHUB_OUTPUT"
echo "inventory=${INVENTORY_JSON}" >> "$GITHUB_OUTPUT"
