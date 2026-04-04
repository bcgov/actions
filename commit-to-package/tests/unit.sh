#!/usr/bin/env bash
# Unit tests for commit-to-package logic (non-Docker parts)

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

# Test framework
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
failed=0

assert_eq() {
    local actual="$1"
    local expected="$2"
    local name="$3"
    
    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        failed=$((failed + 1))
    fi
}

# Run tests
echo "Running commit-to-package unit tests..."
echo

test_parse_image_mapping_single
test_parse_image_mapping_multiple
test_build_json_single
test_build_json_empty
test_git_rev_parse
test_git_head_resolution
test_git_history_traversal

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi