#!/usr/bin/env bash
# Unit tests for test-and-analyse cache determination logic.

set -euo pipefail

passed=0
failed=0

determine_cache() {
    local CACHE_VAL="$1"
    local LANG="$2"
    local RESULT=""

    case "${CACHE_VAL,,}" in
      ""|"none"|"false"|"off"|"0"|"no")
        RESULT=""
        ;;
      *)
        if [ "$LANG" == "node" ]; then
           if [[ "$CACHE_VAL" == "yarn" || "$CACHE_VAL" == "pnpm" ]]; then RESULT="$CACHE_VAL"; else RESULT="npm"; fi
        elif [ "$LANG" == "java" ]; then
           if [[ "$CACHE_VAL" == "gradle" || "$CACHE_VAL" == "sbt" ]]; then RESULT="$CACHE_VAL"; else RESULT="maven"; fi
        elif [ "$LANG" == "python" ]; then
           if [[ "$CACHE_VAL" == "pipenv" || "$CACHE_VAL" == "poetry" ]]; then RESULT="$CACHE_VAL"; else RESULT="pip"; fi
        fi
        ;;
    esac
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

# Node cache disabled cases
assert_cache "" "node" "" "node: empty string disables caching"
assert_cache "none" "node" "" "node: 'none' disables caching"
assert_cache "NONE" "node" "" "node: 'NONE' (uppercase) disables caching"
assert_cache "false" "node" "" "node: 'false' disables caching"
assert_cache "False" "node" "" "node: 'False' (mixed case) disables caching"
assert_cache "off" "node" "" "node: 'off' disables caching"
assert_cache "0" "node" "" "node: '0' disables caching"

# Node cache enabled cases
assert_cache "npm" "node" "npm" "node: 'npm' selects npm cache"
assert_cache "yarn" "node" "yarn" "node: 'yarn' selects yarn cache"
assert_cache "pnpm" "node" "pnpm" "node: 'pnpm' selects pnpm cache"
assert_cache "default" "node" "npm" "node: other value defaults to npm cache"

# Java cache disabled cases
assert_cache "" "java" "" "java: empty string disables caching"
assert_cache "none" "java" "" "java: 'none' disables caching"
assert_cache "false" "java" "" "java: 'false' disables caching"

# Java cache enabled cases
assert_cache "gradle" "java" "gradle" "java: 'gradle' selects gradle cache"
assert_cache "sbt" "java" "sbt" "java: 'sbt' selects sbt cache"
assert_cache "maven" "java" "maven" "java: 'maven' selects maven cache"
assert_cache "other" "java" "maven" "java: other value defaults to maven cache"

# Python cache disabled cases
assert_cache "" "python" "" "python: empty string disables caching"
assert_cache "none" "python" "" "python: 'none' disables caching"
assert_cache "false" "python" "" "python: 'false' disables caching"

# Python cache enabled cases
assert_cache "pipenv" "python" "pipenv" "python: 'pipenv' selects pipenv cache"
assert_cache "poetry" "python" "poetry" "python: 'poetry' selects poetry cache"
assert_cache "pip" "python" "pip" "python: 'pip' selects pip cache"
assert_cache "other" "python" "pip" "python: other value defaults to pip cache"

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
