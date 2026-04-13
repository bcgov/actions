#!/bin/bash
# Unit tests for image-tracker logic (non-Docker parts)

set -eo pipefail

test_parse_image_mapping_single() {
    local images="frontend=ghcr.io/owner/frontend"
    local component repo
    
    declare -A IMAGE_REPOS
    for pair in $images; do
        component="${pair%%=*}"
        repo="${pair#*=}"
        IMAGE_REPOS["$component"]="$repo"
    done
    
    assert_eq "${IMAGE_REPOS[frontend]}" "ghcr.io/owner/frontend" "Single image mapping"
}

test_parse_image_mapping_multiple() {
    local images="frontend=ghcr.io/owner/frontend backend=ghcr.io/owner/backend"
    local component repo
    
    declare -A IMAGE_REPOS
    for pair in $images; do
        component="${pair%%=*}"
        repo="${pair#*=}"
        IMAGE_REPOS["$component"]="$repo"
    done
    
    assert_eq "${#IMAGE_REPOS[@]}" "2" "Multiple images count"
    assert_eq "${IMAGE_REPOS[frontend]}" "ghcr.io/owner/frontend" "Frontend repo"
    assert_eq "${IMAGE_REPOS[backend]}" "ghcr.io/owner/backend" "Backend repo"
}

test_build_json_single() {
    local FOUND_BUNDLE="frontend=abc123 "
    local component found sha
    
    declare -A IMAGE_REPOS
    IMAGE_REPOS["frontend"]="ghcr.io/owner/frontend"
    
    local FOUND_JSON="{"
    for component in "${!IMAGE_REPOS[@]}"; do
        for found in $FOUND_BUNDLE; do
            if [[ "$found" == "$component="* ]]; then
                sha="${found#*=}"
                FOUND_JSON="${FOUND_JSON}\"$component\": \"$sha\", "
                break
            fi
        done
    done
    # Trim trailing comma and space, then add closing brace
    FOUND_JSON="${FOUND_JSON%, }""}"
    
    assert_eq "$FOUND_JSON" "{\"frontend\": \"abc123\"}" "Single component JSON"
}

test_build_json_empty() {
    local FOUND_BUNDLE=""
    local component found sha
    
    declare -A IMAGE_REPOS
    IMAGE_REPOS["frontend"]="ghcr.io/owner/frontend"
    
    local FOUND_JSON="{"
    for component in "${!IMAGE_REPOS[@]}"; do
        for found in $FOUND_BUNDLE; do
            if [[ "$found" == "$component="* ]]; then
                sha="${found#*=}"
                FOUND_JSON="${FOUND_JSON}\"$component\": \"$sha\", "
                break
            fi
        done
    done
    FOUND_JSON="${FOUND_JSON%, }"
    
    # When no matches, use fallback like the action does
    if [[ "$FOUND_JSON" == "{" ]]; then
        FOUND_JSON="{}"
    fi
    
    assert_eq "$FOUND_JSON" "{}" "Empty bundle returns empty object"
}

test_git_rev_parse() {
    local is_git="false"
    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        is_git="true"
    fi
    assert_eq "$is_git" "true" "Inside git repository"
}

test_git_head_resolution() {
    local sha
    sha=$(git rev-parse HEAD 2>/dev/null)
    local is_valid="false"
    
    if [[ -n "$sha" ]] && [[ "$sha" =~ ^[a-f0-9]{40}$ ]]; then
        is_valid="true"
    fi
    
    assert_eq "$is_valid" "true" "HEAD resolves to valid SHA"
}

test_git_history_traversal() {
    local count=0
    local max_check=10
    
    while [[ $count -lt $max_check ]]; do
        if git rev-parse "HEAD~$count" >/dev/null 2>&1; then
            count=$((count + 1))
        else
            break
        fi
    done
    
    if [[ $count -ge 1 ]]; then
        assert_eq "$count" "$count" "Can traverse commits (found $count)"
    else
        assert_eq "0" "1" "At least one parent commit available"
    fi
}

test_revision_resolution() {
    local head_minus_one
    head_minus_one=$(git rev-parse HEAD~1 2>/dev/null || echo "")
    
    if [[ -n "$head_minus_one" ]]; then
       local REVISION="HEAD~1"
       local RESOLVED
       RESOLVED=$(git rev-list --max-count=1 "$REVISION" 2>/dev/null || true)
       echo "DEBUG: head_minus_one='${head_minus_one}' RESOLVED='${RESOLVED}'"
       assert_eq "$RESOLVED" "$head_minus_one" "HEAD~1 resolves to current parent SHA"
    else
       printf "%b i %b %s\n" "${YELLOW}" "${NC}" "Skipping revision test (need at least 2 commits)"
       passed=$((passed + 1))
    fi
}

# Test framework
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

assert_eq() {
    local actual="$1"
    local expected="$2"
    local name="$3"
    
    if [[ "$actual" == "$expected" ]]; then
        printf "%b ✓ %b %s\n" "${GREEN}" "${NC}" "$name"
        passed=$((passed + 1))
    else
        printf "%b ✗ %b %s\n" "${RED}" "${NC}" "$name"
        printf "  Expected: '%s'\n" "$expected"
        printf "  Actual:   '%s'\n" "$actual"
        failed=$((failed + 1))
    fi
}

test_auto_resolve_mapping() {
    local PACKAGE_NAMES="frontend, Backend, quickstart-openshift"
    local REPOSITORY="bcgov/quickstart-openshift"
    
    # Emulate action.sh logic exactly (comma -> newline -> clean)
    declare -A IMAGE_REPOS
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | tr -d '[:space:]')
        [[ -z "$pkg" ]] && continue
        
        local repo_name="${REPOSITORY#*/}"
        local lc_repo
        lc_repo=$(echo "$REPOSITORY" | tr '[:upper:]' '[:lower:]')
        
        if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
             IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}"
        else
             IMAGE_REPOS["$pkg"]="ghcr.io/${lc_repo}/${pkg,,}"
        fi
    done < <(echo "$PACKAGE_NAMES" | tr ',' '\n')
    
    assert_eq "${#IMAGE_REPOS[@]}" "3" "Correct package count"
    assert_eq "${IMAGE_REPOS[frontend]}" "ghcr.io/bcgov/quickstart-openshift/frontend" "Auto-nested lowercase frontend"
    assert_eq "${IMAGE_REPOS[Backend]}" "ghcr.io/bcgov/quickstart-openshift/backend" "Auto-nested lowercase Backend"
    assert_eq "${IMAGE_REPOS[quickstart-openshift]}" "ghcr.io/bcgov/quickstart-openshift" "Correct base-repo mapping"
}

# Run tests
echo "Running image-tracker unit tests..."
echo
test_auto_resolve_mapping
test_parse_image_mapping_single
test_parse_image_mapping_multiple
test_build_json_single
test_build_json_empty
test_git_rev_parse
test_git_head_resolution
test_git_history_traversal
test_revision_resolution

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi