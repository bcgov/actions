#!/usr/bin/env bash
# Unit tests for diff-triggers trigger parsing logic

set -eo pipefail

test_parse_triggers_single() {
    local triggers_str="('./backend/')"
    local expected="./backend/"
    
    TRIGGERS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && TRIGGERS+=("$line")
    done < <(grep -o "'[^']*'" <<< "$triggers_str" | sed "s/'//g")
    
    assert_eq "${TRIGGERS[0]}" "$expected" "Single trigger parsing"
}

test_parse_triggers_multiple() {
    local triggers_str="('./backend/' './frontend/')"
    
    TRIGGERS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && TRIGGERS+=("$line")
    done < <(grep -o "'[^']*'" <<< "$triggers_str" | sed "s/'//g")
    
    assert_eq "${#TRIGGERS[@]}" "2" "Multiple triggers count"
    assert_eq "${TRIGGERS[0]}" "./backend/" "First trigger"
    assert_eq "${TRIGGERS[1]}" "./frontend/" "Second trigger"
}

test_parse_triggers_quoted_paths() {
    local triggers_str="('./path with spaces/' './another path/')"
    
    TRIGGERS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && TRIGGERS+=("$line")
    done < <(grep -o "'[^']*'" <<< "$triggers_str" | sed "s/'//g")
    
    assert_eq "${#TRIGGERS[@]}" "2" "Quoted paths count"
    assert_eq "${TRIGGERS[0]}" "./path with spaces/" "First quoted path"
}

test_parse_triggers_no_quotes() {
    local triggers_str="./backend/"
    
    TRIGGERS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && TRIGGERS+=("$line")
    done < <(grep -o "'[^']*'" <<< "$triggers_str" | sed "s/'//g")
    
    assert_eq "${#TRIGGERS[@]}" "0" "No triggers when no quotes"
}

test_resolve_ref_pr_event() {
    GITHUB_EVENT_NAME="pull_request"
    GITHUB_BASE_REF="main"
    
    COMPARE_REF=""
    if [[ -z "$COMPARE_REF" ]]; then
        if [[ "$GITHUB_EVENT_NAME" == "pull_request" ]]; then
            COMPARE_REF="origin/$GITHUB_BASE_REF"
        else
            COMPARE_REF="HEAD~1"
        fi
    fi
    
    assert_eq "$COMPARE_REF" "origin/main" "PR event resolves to origin/main"
}

test_resolve_ref_push_event() {
    GITHUB_EVENT_NAME="push"
    
    COMPARE_REF=""
    if [[ -z "$COMPARE_REF" ]]; then
        if [[ "$GITHUB_EVENT_NAME" == "pull_request" ]]; then
            COMPARE_REF="origin/$GITHUB_BASE_REF"
        else
            COMPARE_REF="HEAD~1"
        fi
    fi
    
    assert_eq "$COMPARE_REF" "HEAD~1" "Push event resolves to HEAD~1"
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
echo "Running diff-triggers unit tests..."
echo

test_parse_triggers_single
test_parse_triggers_multiple
test_parse_triggers_quoted_paths
test_parse_triggers_no_quotes
test_resolve_ref_pr_event
test_resolve_ref_push_event

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi