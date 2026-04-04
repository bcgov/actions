#!/usr/bin/env bash
# Unit tests for test-and-analyse action (structure validation)

set -eo pipefail

test_action_yml_exists() {
    if [ ! -f "test-and-analyse/action.yml" ]; then
        echo "✗ action.yml not found"
        exit 1
    fi
    assert_eq "exists" "exists" "action.yml exists"
}

test_action_yml_valid() {
    python3 -c "import yaml; yaml.safe_load(open('test-and-analyse/action.yml'))" 2>/dev/null
    assert_eq "$?" "0" "action.yml is valid YAML"
}

test_package_json_exists() {
    if [ ! -f "test-and-analyse/package.json" ]; then
        echo "✗ package.json not found"
        exit 1
    fi
    assert_eq "exists" "exists" "package.json exists"
}

test_knip_config_exists() {
    if [ ! -f "test-and-analyse/.knip.json" ]; then
        echo "✗ .knip.json not found"
        exit 1
    fi
    assert_eq "exists" "exists" ".knip.json exists"
}

test_license_exists() {
    if [ ! -f "test-and-analyse/LICENSE" ]; then
        echo "✗ LICENSE not found"
        exit 1
    fi
    assert_eq "exists" "exists" "LICENSE exists"
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
echo "Running test-and-analyse unit tests..."
echo

test_action_yml_exists
test_action_yml_valid
test_package_json_exists
test_knip_config_exists
test_license_exists

echo
echo "Results: $passed passed, $failed failed"

if [[ $failed -gt 0 ]]; then
    exit 1
fi