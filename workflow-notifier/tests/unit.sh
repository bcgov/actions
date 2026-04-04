#!/usr/bin/env bash
# Unit tests for workflow-notifier logic

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_parse_labels_single() {
    local labels="bug"
    local labels_array=()
    
    IFS=',' read -r -a labels_array <<< "$labels" || true
    
    assert_eq "${#labels_array[@]}" "1" "Single label count"
    assert_eq "${labels_array[0]}" "bug" "Single label value"
}

test_parse_labels_multiple() {
    local labels="bug,failure,high-priority"
    local labels_array=()
    
    IFS=',' read -r -a labels_array <<< "$labels" || true
    
    assert_eq "${#labels_array[@]}" "3" "Multiple labels count"
    assert_eq "${labels_array[0]}" "bug" "First label"
    assert_eq "${labels_array[1]}" "failure" "Second label"
    assert_eq "${labels_array[2]}" "high-priority" "Third label"
}

test_parse_labels_with_spaces() {
    local labels="bug, failure, high-priority "
    local labels_array=()
    
    IFS=',' read -r -a labels_array <<< "$labels" || true
    
    local label
    local cleaned=()
    for label in "${labels_array[@]}"; do
        label=$(echo "$label" | xargs)
        if [ -n "$label" ]; then
            cleaned+=("$label")
        fi
    done
    
    assert_eq "${#cleaned[@]}" "3" "Labels with spaces count"
    assert_eq "${cleaned[0]}" "bug" "First label trimmed"
    assert_eq "${cleaned[1]}" "failure" "Second label trimmed"
}

test_parse_labels_empty() {
    local labels=""
    local labels_array=()
    
    IFS=',' read -r -a labels_array <<< "$labels" || true
    
    assert_eq "${#labels_array[@]}" "0" "Empty labels count"
}

test_assignee_limit() {
    local assignees="user1,user2,user3,user4,user5,user6,user7,user8,user9,user10,user11,user12"
    local cleaned=$(echo "$assignees" | cut -d',' -f1-10)
    
    local count
    IFS=',' read -ra ADDR <<< "$cleaned"
    count=${#ADDR[@]}
    
    assert_eq "$count" "10" "Assignee limit at 10"
}

test_build_issue_body() {
    local body=""
    local run_url="https://github.com/owner/repo/actions/runs/123"
    
    FINAL_BODY="${body:-"Workflow failure detected at $(date)."}"
    printf -v FINAL_BODY "%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$run_url"
    
    if [[ "$FINAL_BODY" == *"$run_url"* ]]; then
        assert_eq "contains_url" "contains_url" "Body contains run URL"
    else
        assert_eq "contains_url" "missing" "Body should contain URL"
    fi
}

test_build_issue_body_custom() {
    local body="Custom issue body"
    local run_url="https://github.com/owner/repo/actions/runs/123"
    
    FINAL_BODY="${body:-"Workflow failure detected at $(date)."}"
    printf -v FINAL_BODY "%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$run_url"
    
    if [[ "$FINAL_BODY" == "$body"* ]]; then
        assert_eq "starts_with_custom" "starts_with_custom" "Body starts with custom text"
    else
        assert_eq "starts_with_custom" "wrong" "Should start with custom"
    fi
}

test_pr_number_extraction_from_url() {
    local url="https://github.com/owner/repo/issues/456"
    local issue_num=$(echo "$url" | grep -oE '[0-9]+$' || echo "0")
    
    assert_eq "$issue_num" "456" "Extract issue number from URL"
}

test_pr_number_extraction_from_url_dry_run() {
    local url="https://github.com/owner/repo/issues/dry-run"
    local issue_num=$(echo "$url" | grep -oE '[0-9]+$' || echo "0")
    
    assert_eq "$issue_num" "0" "Dry run returns 0"
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
echo "Running workflow-notifier unit tests..."
echo

test_parse_labels_single
test_parse_labels_multiple
test_parse_labels_with_spaces
test_parse_labels_empty
test_assignee_limit
test_build_issue_body
test_build_issue_body_custom
test_pr_number_extraction_from_url
test_pr_number_extraction_from_url_dry_run

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi