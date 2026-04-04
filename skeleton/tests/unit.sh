#!/usr/bin/env bash
# Unit tests for skeleton action (template)

set -eo pipefail

test_debug_log_disabled() {
    INPUT_DEBUG="false"
    
    log_debug() {
        if [ "${INPUT_DEBUG}" == "true" ]; then
            echo "DEBUG: $1"
        fi
    }
    
    output=$(log_debug "test message" 2>&1)
    
    assert_eq "$output" "" "Debug logging disabled"
}

test_debug_log_enabled() {
    INPUT_DEBUG="true"
    
    log_debug() {
        if [ "${INPUT_DEBUG}" == "true" ]; then
            echo "DEBUG: $1"
        fi
    }
    
    output=$(log_debug "test message" 2>&1)
    
    assert_eq "$output" "DEBUG: test message" "Debug logging enabled"
}

test_debug_log_empty() {
    INPUT_DEBUG=""
    
    log_debug() {
        if [ "${INPUT_DEBUG}" == "true" ]; then
            echo "DEBUG: $1"
        fi
    }
    
    output=$(log_debug "test message" 2>&1)
    
    assert_eq "$output" "" "Debug logging with empty input"
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
echo "Running skeleton unit tests..."
echo

test_debug_log_disabled
test_debug_log_enabled
test_debug_log_empty

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi