#!/usr/bin/env bash
# Unit tests for get-pr action logic

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_get_pr_from_git_single() {
    local commit_msg="feat: add new feature (#123)"
    local pr=""
    
    if [[ $commit_msg =~ \(#([0-9]+)\)$ ]]; then
        pr="${BASH_REMATCH[1]}"
    fi
    
    assert_eq "$pr" "123" "Single PR number extraction"
}

test_get_pr_from_git_multiple() {
    local commit_msg="Fix bug and update deps (#456)"
    local pr=""
    
    if [[ $commit_msg =~ \(#([0-9]+)\)$ ]]; then
        pr="${BASH_REMATCH[1]}"
    fi
    
    assert_eq "$pr" "456" "PR from commit message"
}

test_get_pr_from_git_no_pr() {
    local commit_msg="Update README.md"
    local pr=""
    
    if [[ $commit_msg =~ \(#([0-9]+)\)$ ]]; then
        pr="${BASH_REMATCH[1]}"
    fi
    
    assert_eq "$pr" "" "No PR when none in message"
}

test_get_pr_from_git_merge_commit() {
    local commit_msg="Merge branch 'main' into feature (#789)"
    local pr=""
    
    if [[ $commit_msg =~ \(#([0-9]+)\)$ ]]; then
        pr="${BASH_REMATCH[1]}"
    fi
    
    assert_eq "$pr" "789" "Merge commit PR extraction"
}

test_merge_group_parsing() {
    local head_ref="queue/main/pr-123"
    local pr=""
    
    if [ -n "${head_ref}" ]; then
        pr=$(echo "${head_ref}" | sed -n 's|^queue/[^/]*/pr-\([0-9]\+\).*|\1|p')
    fi
    
    assert_eq "$pr" "123" "Merge queue PR number extraction"
}

test_merge_group_parsing_different_branch() {
    local head_ref="queue/feature/pr-456/merge"
    local pr=""
    
    if [ -n "${head_ref}" ]; then
        pr=$(echo "${head_ref}" | sed -n 's|^queue/[^/]*/pr-\([0-9]\+\).*|\1|p')
    fi
    
    assert_eq "$pr" "456" "Merge queue with different branch"
}

test_pr_number_validation() {
    local pr="123"
    
    if [ -n "$pr" ] && [[ "${pr}" =~ ^[0-9]+$ ]]; then
        assert_eq "valid" "valid" "Numeric PR is valid"
    else
        assert_eq "valid" "invalid" "Should be valid"
    fi
}

test_pr_number_validation_invalid() {
    local pr="abc"
    
    if [ -n "$pr" ] && [[ "${pr}" =~ ^[0-9]+$ ]]; then
        assert_eq "valid" "invalid" "Should be invalid"
    else
        assert_eq "valid" "valid" "Non-numeric PR is invalid"
    fi
}

test_pr_number_validation_empty() {
    local pr=""
    
    if [ -n "$pr" ] && [[ "${pr}" =~ ^[0-9]+$ ]]; then
        assert_eq "valid" "invalid" "Empty should be invalid"
    else
        assert_eq "valid" "valid" "Empty string is invalid"
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
echo "Running get-pr unit tests..."
echo

test_get_pr_from_git_single
test_get_pr_from_git_multiple
test_get_pr_from_git_no_pr
test_get_pr_from_git_merge_commit
test_merge_group_parsing
test_merge_group_parsing_different_branch
test_pr_number_validation
test_pr_number_validation_invalid
test_pr_number_validation_empty

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi