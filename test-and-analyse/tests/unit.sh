#!/usr/bin/env bash
# Unit tests for test-and-analyse cache determination logic.

set -euo pipefail

passed=0
failed=0

determine_cache() {
    local CACHE_VAL="$1"
    local LANG="$2"
    local RESULT=""

    if [ "${CACHE_VAL,,}" == "none" ]; then
       RESULT=""
    elif [ "$LANG" == "node" ]; then
       if [[ "$CACHE_VAL" == "yarn" || "$CACHE_VAL" == "pnpm" ]]; then RESULT="$CACHE_VAL"; else RESULT="npm"; fi
    elif [ "$LANG" == "java" ]; then
       if [[ "$CACHE_VAL" == "gradle" || "$CACHE_VAL" == "sbt" ]]; then RESULT="$CACHE_VAL"; else RESULT="maven"; fi
    elif [ "$LANG" == "python" ]; then
       if [[ "$CACHE_VAL" == "pipenv" || "$CACHE_VAL" == "poetry" ]]; then RESULT="$CACHE_VAL"; else RESULT="pip"; fi
    fi
    printf '%s' "$RESULT"
}

assert_cache() {
    local cache_input="$1"
    local lang_input="$2"
    local expected="$3"
    local name="$4"

    local actual
    actual="$(determine_cache "$cache_input" "$lang_input")"

    if [[ "$actual" == "$expected" ]]; then
        echo "✓ $name"
        passed=$((passed + 1))
    else
        echo "✗ $name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        failed=$((failed + 1))
    fi
}

echo "Running test-and-analyse unit tests..."

# Node cache disabled cases (explicit opt-out only)
assert_cache "none" "node" "" "node: 'none' disables caching"
assert_cache "None" "node" "" "node: 'None' disables caching"
assert_cache "NONE" "node" "" "node: 'NONE' (uppercase) disables caching"

# Node cache enabled by default / package managers
assert_cache "" "node" "npm" "node: empty string preserves default npm cache"
assert_cache "npm" "node" "npm" "node: 'npm' selects npm cache"
assert_cache "yarn" "node" "yarn" "node: 'yarn' selects yarn cache"
assert_cache "pnpm" "node" "pnpm" "node: 'pnpm' selects pnpm cache"
assert_cache "default" "node" "npm" "node: unknown string defaults to npm cache"

# Java cache disabled cases (explicit opt-out only)
assert_cache "none" "java" "" "java: 'none' disables caching"
assert_cache "NONE" "java" "" "java: 'NONE' disables caching"

# Java cache enabled by default / package managers
assert_cache "" "java" "maven" "java: empty string preserves default maven cache"
assert_cache "gradle" "java" "gradle" "java: 'gradle' selects gradle cache"
assert_cache "sbt" "java" "sbt" "java: 'sbt' selects sbt cache"
assert_cache "maven" "java" "maven" "java: 'maven' selects maven cache"

# Python cache disabled cases (explicit opt-out only)
assert_cache "none" "python" "" "python: 'none' disables caching"
assert_cache "None" "python" "" "python: 'None' disables caching"

# Python cache enabled by default / package managers
assert_cache "" "python" "pip" "python: empty string preserves default pip cache"
assert_cache "pipenv" "python" "pipenv" "python: 'pipenv' selects pipenv cache"
assert_cache "poetry" "python" "poetry" "python: 'poetry' selects poetry cache"
assert_cache "pip" "python" "pip" "python: 'pip' selects pip cache"

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
