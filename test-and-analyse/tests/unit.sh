#!/usr/bin/env bash
# Unit tests for test-and-analyse cache determination, auto-detection, and fail-fast validation.

set -euo pipefail

passed=0
failed=0

determine_cache() {
    local CACHE_VAL="$1"
    local LANG="$2"
    local DIR="${3:-.}"
    local ROOT="${4:-.}"
    local VAL="${CACHE_VAL,,}"
    local RESULT=""

    if [ "$VAL" == "none" ]; then
        RESULT=""
    elif [ -n "$VAL" ]; then
        # Explicit value provided: validate strictly per language
        case "$LANG" in
            node)
                case "$VAL" in
                    npm|yarn|pnpm) RESULT="$VAL" ;;
                    *) echo "::error::Invalid cache value '${CACHE_VAL}' for language '${LANG}'. Allowed values: npm, yarn, pnpm, none." >&2; return 1 ;;
                esac
                ;;
            java)
                case "$VAL" in
                    maven|gradle|sbt) RESULT="$VAL" ;;
                    *) echo "::error::Invalid cache value '${CACHE_VAL}' for language '${LANG}'. Allowed values: maven, gradle, sbt, none." >&2; return 1 ;;
                esac
                ;;
            python)
                case "$VAL" in
                    pip|poetry|pipenv) RESULT="$VAL" ;;
                    *) echo "::error::Invalid cache value '${CACHE_VAL}' for language '${LANG}'. Allowed values: pip, poetry, pipenv, none." >&2; return 1 ;;
                esac
                ;;
            *)
                echo "::error::Unsupported language: $LANG" >&2; return 1 ;;
        esac
    else
        # Auto-detect when cache input is omitted
        case "$LANG" in
            node)
                if [ -f "$DIR/pnpm-lock.yaml" ] || [ -f "$ROOT/pnpm-lock.yaml" ]; then
                    RESULT="pnpm"
                elif [ -f "$DIR/yarn.lock" ] || [ -f "$ROOT/yarn.lock" ]; then
                    RESULT="yarn"
                else
                    RESULT="npm"
                fi
                ;;
            java)
                if [ -f "$DIR/build.gradle" ] || [ -f "$DIR/build.gradle.kts" ] || [ -f "$DIR/gradlew" ] || \
                   [ -f "$ROOT/build.gradle" ] || [ -f "$ROOT/build.gradle.kts" ] || [ -f "$ROOT/gradlew" ]; then
                    RESULT="gradle"
                elif [ -f "$DIR/build.sbt" ] || [ -f "$ROOT/build.sbt" ]; then
                    RESULT="sbt"
                else
                    RESULT="maven"
                fi
                ;;
            python)
                if [ -f "$DIR/poetry.lock" ] || [ -f "$ROOT/poetry.lock" ]; then
                    RESULT="poetry"
                elif [ -f "$DIR/Pipfile" ] || [ -f "$DIR/Pipfile.lock" ] || [ -f "$ROOT/Pipfile" ] || [ -f "$ROOT/Pipfile.lock" ]; then
                    RESULT="pipenv"
                else
                    RESULT="pip"
                fi
                ;;
            *)
                echo "::error::Unsupported language: $LANG" >&2; return 1 ;;
        esac
    fi

    printf '%s' "$RESULT"
}

assert_cache() {
    local cache_input="$1"
    local lang_input="$2"
    local dir_input="$3"
    local root_input="$4"
    local expected="$5"
    local name="$6"

    local actual
    actual="$(determine_cache "$cache_input" "$lang_input" "$dir_input" "$root_input")"

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

assert_fails() {
    local cache_input="$1"
    local lang_input="$2"
    local name="$3"

    if ! determine_cache "$cache_input" "$lang_input" "." "." 2>/dev/null; then
        echo "✓ $name"
        passed=$((passed + 1))
    else
        echo "✗ $name"
        echo "  Expected failure, but command succeeded"
        failed=$((failed + 1))
    fi
}

echo "Running test-and-analyse unit tests..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Setup test fixtures
mkdir -p "$TMP_DIR/node-pnpm" && touch "$TMP_DIR/node-pnpm/pnpm-lock.yaml"
mkdir -p "$TMP_DIR/node-yarn" && touch "$TMP_DIR/node-yarn/yarn.lock"
mkdir -p "$TMP_DIR/node-npm" && touch "$TMP_DIR/node-npm/package-lock.json"
mkdir -p "$TMP_DIR/node-workspace/subpkg" && touch "$TMP_DIR/node-workspace/package-lock.json"
mkdir -p "$TMP_DIR/node-empty"

mkdir -p "$TMP_DIR/java-gradle" && touch "$TMP_DIR/java-gradle/build.gradle"
mkdir -p "$TMP_DIR/java-gradle-kts" && touch "$TMP_DIR/java-gradle-kts/build.gradle.kts"
mkdir -p "$TMP_DIR/java-gradlew" && touch "$TMP_DIR/java-gradlew/gradlew"
mkdir -p "$TMP_DIR/java-sbt" && touch "$TMP_DIR/java-sbt/build.sbt"
mkdir -p "$TMP_DIR/java-maven" && touch "$TMP_DIR/java-maven/pom.xml"
mkdir -p "$TMP_DIR/java-empty"

mkdir -p "$TMP_DIR/py-poetry" && touch "$TMP_DIR/py-poetry/poetry.lock"
mkdir -p "$TMP_DIR/py-pipenv" && touch "$TMP_DIR/py-pipenv/Pipfile"
mkdir -p "$TMP_DIR/py-pip" && touch "$TMP_DIR/py-pip/requirements.txt"
mkdir -p "$TMP_DIR/py-empty"

# --- 1. Node Auto-detection ---
assert_cache "" "node" "$TMP_DIR/node-pnpm" "$TMP_DIR/node-pnpm" "pnpm" "node: auto-detects pnpm from pnpm-lock.yaml"
assert_cache "" "node" "$TMP_DIR/node-yarn" "$TMP_DIR/node-yarn" "yarn" "node: auto-detects yarn from yarn.lock"
assert_cache "" "node" "$TMP_DIR/node-npm" "$TMP_DIR/node-npm" "npm" "node: auto-detects npm from package-lock.json"
assert_cache "" "node" "$TMP_DIR/node-workspace/subpkg" "$TMP_DIR/node-workspace" "npm" "node: auto-detects root package-lock.json in monorepo workspace"
assert_cache "" "node" "$TMP_DIR/node-empty" "$TMP_DIR/node-empty" "npm" "node: defaults to npm when no lockfile is found"

# --- 2. Java Auto-detection ---
assert_cache "" "java" "$TMP_DIR/java-gradle" "$TMP_DIR/java-gradle" "gradle" "java: auto-detects gradle from build.gradle"
assert_cache "" "java" "$TMP_DIR/java-gradle-kts" "$TMP_DIR/java-gradle-kts" "gradle" "java: auto-detects gradle from build.gradle.kts"
assert_cache "" "java" "$TMP_DIR/java-gradlew" "$TMP_DIR/java-gradlew" "gradle" "java: auto-detects gradle from gradlew"
assert_cache "" "java" "$TMP_DIR/java-sbt" "$TMP_DIR/java-sbt" "sbt" "java: auto-detects sbt from build.sbt"
assert_cache "" "java" "$TMP_DIR/java-maven" "$TMP_DIR/java-maven" "maven" "java: auto-detects maven from pom.xml"
assert_cache "" "java" "$TMP_DIR/java-empty" "$TMP_DIR/java-empty" "maven" "java: defaults to maven when no build file is found"

# --- 3. Python Auto-detection ---
assert_cache "" "python" "$TMP_DIR/py-poetry" "$TMP_DIR/py-poetry" "poetry" "python: auto-detects poetry from poetry.lock"
assert_cache "" "python" "$TMP_DIR/py-pipenv" "$TMP_DIR/py-pipenv" "pipenv" "python: auto-detects pipenv from Pipfile"
assert_cache "" "python" "$TMP_DIR/py-empty" "$TMP_DIR/py-empty" "pip" "python: defaults to pip when no manifest is found"

# --- 4. Explicit Opt-Out ('none') ---
assert_cache "none" "node" "$TMP_DIR/node-pnpm" "$TMP_DIR/node-pnpm" "" "node: 'none' disables caching even if pnpm-lock.yaml exists"
assert_cache "None" "node" "$TMP_DIR/node-pnpm" "$TMP_DIR/node-pnpm" "" "node: 'None' (case-insensitive) disables caching"
assert_cache "NONE" "java" "$TMP_DIR/java-gradle" "$TMP_DIR/java-gradle" "" "java: 'NONE' disables caching even if build.gradle exists"
assert_cache "none" "python" "$TMP_DIR/py-poetry" "$TMP_DIR/py-poetry" "" "python: 'none' disables caching even if poetry.lock exists"

# --- 5. Explicit Valid Overrides ---
assert_cache "npm" "node" "$TMP_DIR/node-yarn" "$TMP_DIR/node-yarn" "npm" "node: explicit npm overrides yarn.lock"
assert_cache "yarn" "node" "$TMP_DIR/node-npm" "$TMP_DIR/node-npm" "yarn" "node: explicit yarn overrides package-lock.json"
assert_cache "pnpm" "node" "$TMP_DIR/node-npm" "$TMP_DIR/node-npm" "pnpm" "node: explicit pnpm overrides package-lock.json"
assert_cache "maven" "java" "$TMP_DIR/java-gradle" "$TMP_DIR/java-gradle" "maven" "java: explicit maven overrides build.gradle"
assert_cache "gradle" "java" "$TMP_DIR/java-maven" "$TMP_DIR/java-maven" "gradle" "java: explicit gradle overrides pom.xml"
assert_cache "pip" "python" "$TMP_DIR/py-poetry" "$TMP_DIR/py-poetry" "pip" "python: explicit pip overrides poetry.lock"

# --- 6. Fail-Fast on Invalid Values ---
assert_fails "yran" "node" "node: fails fast on typo 'yran'"
assert_fails "false" "node" "node: fails fast on boolean 'false'"
assert_fails "npm" "java" "java: fails fast on node manager 'npm'"
assert_fails "gradle" "python" "python: fails fast on java manager 'gradle'"
assert_fails "npm" "unsupported" "fails fast on unsupported language"

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
