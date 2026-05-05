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
COSIGN_ENABLED="${INPUT_COSIGN:-false}"
COSIGN_PUB_KEY="${INPUT_COSIGN_PUBLIC_KEY:-}"

# Parse package names if provided
declare -A IMAGE_REPOS
FIRST_PKG=""
repo_name="${REPOSITORY#*/}"
lc_repo=$(echo "$REPOSITORY" | tr '[:upper:]' '[:lower:]')

if [[ -n "$PACKAGE_INPUT" ]]; then
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | tr -d '[:space:]')
        [[ -z "$pkg" ]] && continue
        [[ -z "$FIRST_PKG" ]] && FIRST_PKG="$pkg"
        # If the package name matches the repo name, image lives at the repo root path
        if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
            IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}"
        else
            IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}/${pkg,,}"
        fi
    done < <(echo "$PACKAGE_INPUT" | tr ',' '\n')
fi

cd "$DIR" || { echo "::error::Could not change to directory $DIR"; exit 1; }

echo "::group::Workflow Walker — Forensic History Traversal"
echo "  Target Repository: $REPOSITORY"
echo "  Starting Revision: $REVISION"
echo "  Max Depth: $MAX_DEPTH"
if [[ ${#IMAGE_REPOS[@]} -gt 0 ]]; then
    echo "  Packages: ${!IMAGE_REPOS[*]}"
else
    echo "  Mode: PR Metadata Resolution (Dumb Walk)"
fi
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
# Track what was found at least once during the walk (for inventory mode success)
EVER_FOUND_COUNT=0
declare -A COMPONENT_FOUND_MAP

check_image() {
    local component="$1"
    local sha="$2"
    local desc="$3"
    local target_commit="$4"
    local pr_num="$5"

    local full_sha_tag="${IMAGE_REPOS[$component]}:sha-${sha}"
    local short_sha_tag="${IMAGE_REPOS[$component]}:sha-${sha:0:7}"

    # Try tags in order of specificity (Long SHA then Short SHA)
    local tags_to_check=("$full_sha_tag" "$short_sha_tag")

    for tag in "${tags_to_check[@]}"; do
        local is_valid="false"
        local has_sbom="false"
        if [[ "$COSIGN_ENABLED" == "true" ]]; then
            if [[ -n "$COSIGN_PUB_KEY" ]]; then
                echo "$COSIGN_PUB_KEY" > /tmp/cosign.pub
                if cosign verify --key /tmp/cosign.pub "$tag" > /dev/null 2>&1; then
                    is_valid="true"
                    # Also check for SBOM attestations (CycloneDX or SPDX)
                    if cosign verify-attestation --key /tmp/cosign.pub --type cyclonedx "$tag" > /dev/null 2>&1 || \
                       cosign verify-attestation --key /tmp/cosign.pub --type spdxjson "$tag" > /dev/null 2>&1; then
                        has_sbom="true"
                    fi
                fi
            else
                # Keyless verification
                if cosign verify "$tag" > /dev/null 2>&1; then
                    is_valid="true"
                    if cosign verify-attestation --type cyclonedx "$tag" > /dev/null 2>&1 || \
                       cosign verify-attestation --type spdxjson "$tag" > /dev/null 2>&1; then
                        has_sbom="true"
                    fi
                fi
            fi
        else
            if docker manifest inspect "$tag" > /dev/null 2>&1; then
                is_valid="true"
            fi
        fi

        if [[ "$is_valid" == "true" ]]; then
            local tag_only="${tag##*:}"
            local signed_status="[ ]"
            [[ "$COSIGN_ENABLED" == "true" ]] && signed_status="[✓]"
            local sbom_status="[ ]"
            [[ "$has_sbom" == "true" ]] && sbom_status="[✓]"

            echo "  [✓] FOUND ($desc): $component -> $tag_only (Signed: $signed_status, SBOM: $sbom_status)"
            echo "::notice title=Image Resolved::Package '$component' resolved to $tag_only ($desc) [Signed: $signed_status, SBOM: $sbom_status]"
            
            # In inventory mode, we track EVERYTHING found
            if [[ "$INVENTORY_MODE" == "true" ]]; then
                local merge_date
                # Convert to UTC (Zulu) time
                local ts
                ts=$(git log -1 --format=%at "$target_commit" 2>/dev/null || echo "")
                if [[ -n "$ts" ]]; then
                    merge_date=$(date -u -d "@$ts" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$ts" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
                else
                    merge_date="unknown"
                fi
                
                local current_pr="${PR_NUM_MAP[$target_commit]:-N/A}"
                INVENTORY_JSON=$(echo "$INVENTORY_JSON" | jq -c --arg c "$component" --arg s "$tag_only" --arg d "$merge_date" --arg p "$current_pr" \
                    --arg sig "$signed_status" --arg sbom "$sbom_status" \
                    '. += [{"package": $c, "tag": $s, "merged_at": $d, "pr": $p, "signed": $sig, "sbom": $sbom}]')
            fi

            FOUND_BUNDLE_JSON=$(echo "$FOUND_BUNDLE_JSON" | jq -c --arg c "$component" --arg s "$tag_only" '.[$c] = $s')
            
            if [[ -z "${COMPONENT_FOUND_MAP[$component]:-}" ]]; then
                COMPONENT_FOUND_MAP["$component"]="true"
                EVER_FOUND_COUNT=$((EVER_FOUND_COUNT + 1))
            fi
            
            return 0
        fi
    done

    echo "  [x] MISSING ($desc): $component -> sha-${sha:0:7} (and long fallback)"
    return 1
}

# Track top-level resolved PR
RESOLVED_PR=""

declare -A PR_MAP
declare -A PR_NUM_MAP
if [[ -n "$GH_TOKEN" ]]; then
    echo "  [i] Batch-fetching PR merge map for $REPOSITORY..."
    PR_DATA=$(gh api --paginate "/repos/${REPOSITORY}/pulls?state=all&per_page=100" \
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
    
    # 1. Resolve PR metadata
    PR_HEAD_SHA="${PR_MAP[$TARGET_SHA]:-}"
    PR_NUM="${PR_NUM_MAP[$TARGET_SHA]:-}"
    [[ -z "$RESOLVED_PR" ]] && [[ -n "$PR_NUM" && "$PR_NUM" != "null" ]] && RESOLVED_PR="$PR_NUM"

    # 2. Check associated PR head SHA (covers squash merges)
    if [[ -n "$PR_HEAD_SHA" && "$PR_HEAD_SHA" != "null" && "$PR_HEAD_SHA" != "$TARGET_SHA" ]]; then
        REFRESHED=()
        if [[ ${#IMAGE_REPOS[@]} -gt 0 ]]; then
            for component in "${NOT_FOUND_COMPONENTS[@]}"; do
                check_image "$component" "$PR_HEAD_SHA" "PR #$PR_NUM Head" "$TARGET_SHA" "$PR_NUM" || REFRESHED+=("$component")
            done
        fi
        # Only update NOT_FOUND if we aren't in inventory mode (in inventory mode, we keep searching)
        if [[ "$INVENTORY_MODE" != "true" ]]; then
            NOT_FOUND_COMPONENTS=("${REFRESHED[@]}")
        fi
    fi

    # 3. Check the commit SHA itself (covers standard merges)
    # If in pure PR mode, we still "check" once to populate inventory if requested
    if [[ "$INVENTORY_MODE" == "true" || ${#NOT_FOUND_COMPONENTS[@]} -gt 0 || ${#IMAGE_REPOS[@]} -eq 0 ]]; then
        REFRESHED=()
        if [[ ${#IMAGE_REPOS[@]} -gt 0 ]]; then
            for component in "${NOT_FOUND_COMPONENTS[@]}"; do
                check_image "$component" "$TARGET_SHA" "Commit SHA" "$TARGET_SHA" "$PR_NUM" || REFRESHED+=("$component")
            done
        else
            # Pure PR resolution mode: just track the metadata for inventory
            if [[ "$INVENTORY_MODE" == "true" ]]; then
                local merge_date
                local ts
                ts=$(git log -1 --format=%at "$TARGET_SHA" 2>/dev/null || echo "")
                if [[ -n "$ts" ]]; then
                    merge_date=$(date -u -d "@$ts" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$ts" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
                else
                    merge_date="unknown"
                fi
                INVENTORY_JSON=$(echo "$INVENTORY_JSON" | jq -c --arg d "$merge_date" --arg p "${PR_NUM:-N/A}" \
                    '. += [{"package": "N/A", "tag": "N/A", "merged_at": $d, "pr": $p, "signed": "N/A", "sbom": "N/A"}]')
            fi
        fi
        if [[ "$INVENTORY_MODE" != "true" ]]; then
            NOT_FOUND_COMPONENTS=("${REFRESHED[@]}")
        fi
    fi

    if [[ "$INVENTORY_MODE" != "true" && ${#IMAGE_REPOS[@]} -gt 0 && ${#NOT_FOUND_COMPONENTS[@]} -eq 0 ]]; then
        echo "  [!] Success: All packages resolved."
        break
    fi
    # If in pure PR mode and not inventory, we only need the first commit's PR
    if [[ "$INVENTORY_MODE" != "true" && ${#IMAGE_REPOS[@]} -eq 0 ]]; then
        break
    fi
done

if [[ "$INVENTORY_MODE" == "true" ]]; then
    echo ""
    echo "  [i] Inventory Summary:"
    if [[ ${#IMAGE_REPOS[@]} -gt 0 ]]; then
        echo "$INVENTORY_JSON" | jq -r '["PACKAGE", "TAG", "PR", "MERGED_AT", "SIGNED", "SBOM"], (.[] | [.package, .tag, .pr, .merged_at, .signed, .sbom]) | @tsv' | column -t -s $'\t' || true
    else
        echo "$INVENTORY_JSON" | jq -r '["PR", "MERGED_AT"], (.[] | [.pr, .merged_at]) | @tsv' | column -t -s $'\t' || true
    fi
    echo ""
    
    # Add to GitHub Step Summary
    {
        echo "### 🔍 Image Inventory Audit"
        if [[ ${#IMAGE_REPOS[@]} -gt 0 ]]; then
            echo "| Package | Tag | PR | Merged (UDT) | Signed | SBOM |"
            echo "| --- | --- | --- | --- | --- | --- |"
            echo "$INVENTORY_JSON" | jq -r '.[] | "| \(.package) | `\(.tag)` | #\(.pr) | \(.merged_at) | \(.signed) | \(.sbom) |"'
        else
            echo "| PR | Merged (UDT) |"
            echo "| --- | --- |"
            echo "$INVENTORY_JSON" | jq -r '.[] | "| #\(.pr) | \(.merged_at) |"'
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi

echo "::endgroup::"

# Success/Failure criteria
FAILED_COMPONENTS=()
if [[ ${#IMAGE_REPOS[@]} -gt 0 ]]; then
    if [[ "$INVENTORY_MODE" == "true" ]]; then
        for component in "${!IMAGE_REPOS[@]}"; do
            if [[ -z "${COMPONENT_FOUND_MAP[$component]:-}" ]]; then
                FAILED_COMPONENTS+=("$component")
            fi
        done
    else
        FAILED_COMPONENTS=("${NOT_FOUND_COMPONENTS[@]}")
    fi
fi

if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
    echo "::error::Failed to resolve packages after checking $ACTUAL_COMMIT_COUNT commit(s) (Max limit: $MAX_DEPTH): ${FAILED_COMPONENTS[*]}"
    exit 1
fi

{
    echo "packages=${FOUND_BUNDLE_JSON}"
    echo "bundle=${FOUND_BUNDLE_JSON}"
    echo "inventory=${INVENTORY_JSON}"
    echo "pr=${RESOLVED_PR}"
} >> "$GITHUB_OUTPUT"

# Simplified single tag output (first package)
if [[ -n "$FIRST_PKG" ]]; then
    FIRST_TAG=$(echo "$FOUND_BUNDLE_JSON" | jq -r --arg p "$FIRST_PKG" '.[$p] // empty')
    if [[ -n "$FIRST_TAG" ]]; then
        echo "tag=${FIRST_TAG}" >> "$GITHUB_OUTPUT"
        # If there were multiple packages, let the user know which one 'tag' refers to
        if [[ $(echo "$PACKAGE_INPUT" | tr ',' '\n' | grep -vc '^$' || echo 0) -gt 1 ]]; then
            echo "  [i] Note: Multiple packages resolved. 'tag' output set to first package: $FIRST_PKG"
        fi
    fi
fi
