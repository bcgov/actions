#!/usr/bin/env bash
# Unit tests for test-and-analyse cache determination, auto-detection, and fail-fast validation.

set -euo pipefail

passed=0
failed=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_SCRIPT="${SCRIPT_DIR}/../cache.sh"

determine_cache() {
    local CACHE_VAL="$1"
    local LANG="$2"
    local DIR="${3:-.}"
    local ROOT="${4:-.}"

    local out_file
    out_file="$(mktemp)"

    if GITHUB_OUTPUT="$out_file" \
       INPUT_CACHE="$CACHE_VAL" \
       INPUT_LANGUAGE="$LANG" \
       INPUT_DIR="$DIR" \
       INPUT_CHECKOUT_PATH="$ROOT" \
       bash "$CACHE_SCRIPT" >/dev/null 2>&1; then
        local result=""
        if grep -q '^cache=' "$out_file"; then
            result="$(grep '^cache=' "$out_file" | cut -d= -f2-)"
        fi
        rm -f "$out_file"
        printf '%s' "$result"
        return 0
    else
        rm -f "$out_file"
        return 1
    fi
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

# ==============================================================================
# Node.js Version Determination & Auto-Detection Tests
# ==============================================================================
NODE_VERSION_SCRIPT="${SCRIPT_DIR}/../node-version.sh"

determine_node_version() {
    local VER="$1"
    local VER_FILE="$2"
    local DIR="${3:-.}"
    local ROOT="${4:-.}"

    local out_file
    out_file="$(mktemp)"

    if GITHUB_OUTPUT="$out_file" \
       INPUT_NODE_VERSION="$VER" \
       INPUT_NODE_VERSION_FILE="$VER_FILE" \
       INPUT_DIR="$DIR" \
       INPUT_CHECKOUT_PATH="$ROOT" \
       bash "$NODE_VERSION_SCRIPT" >/dev/null 2>&1; then
        local ver_out=""
        local file_out=""
        if grep -q '^node_version=' "$out_file"; then
            ver_out="$(grep '^node_version=' "$out_file" | cut -d= -f2-)"
        fi
        if grep -q '^node_version_file=' "$out_file"; then
            file_out="$(grep '^node_version_file=' "$out_file" | cut -d= -f2-)"
        fi
        rm -f "$out_file"
        printf '%s|%s' "$ver_out" "$file_out"
        return 0
    else
        rm -f "$out_file"
        return 1
    fi
}

assert_node_version() {
    local ver_in="$1"
    local file_in="$2"
    local dir_in="$3"
    local root_in="$4"
    local expected="$5" # format: version|version_file
    local name="$6"

    local actual
    actual="$(determine_node_version "$ver_in" "$file_in" "$dir_in" "$root_in")"

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

assert_node_version_fails() {
    local ver_in="$1"
    local file_in="$2"
    local dir_in="$3"
    local root_in="$4"
    local name="$5"

    if ! determine_node_version "$ver_in" "$file_in" "$dir_in" "$root_in" 2>/dev/null; then
        echo "✓ $name"
        passed=$((passed + 1))
    else
        echo "✗ $name"
        echo "  Expected failure, but command succeeded"
        failed=$((failed + 1))
    fi
}

echo ""
echo "Running node-version auto-detection unit tests..."

# Node version fixtures
mkdir -p "$TMP_DIR/nv-node-version" && echo "20.10.0" > "$TMP_DIR/nv-node-version/.node-version"
mkdir -p "$TMP_DIR/nv-nvmrc" && echo "22.0.0" > "$TMP_DIR/nv-nvmrc/.nvmrc"
mkdir -p "$TMP_DIR/nv-dockerfile-slim" && echo "FROM node:22-bookworm-slim" > "$TMP_DIR/nv-dockerfile-slim/Dockerfile"
mkdir -p "$TMP_DIR/nv-dockerfile-distroless" && echo "FROM gcr.io/distroless/nodejs20-debian12" > "$TMP_DIR/nv-dockerfile-distroless/Dockerfile"
mkdir -p "$TMP_DIR/nv-dockerfile-fullver" && echo "FROM docker.io/library/node:24.20.0" > "$TMP_DIR/nv-dockerfile-fullver/Dockerfile"
mkdir -p "$TMP_DIR/nv-dockerfile-commented"
cat << 'EOF' > "$TMP_DIR/nv-dockerfile-commented/Dockerfile"
# FROM node:18-alpine
  from --platform=linux/amd64 docker.io/library/node:22.14.0-bookworm
EOF
mkdir -p "$TMP_DIR/nv-pkg-engines" && echo '{"name":"test","engines":{"node":">=20.0.0"}}' > "$TMP_DIR/nv-pkg-engines/package.json"
mkdir -p "$TMP_DIR/nv-pkg-no-engines" && echo '{"name":"test"}' > "$TMP_DIR/nv-pkg-no-engines/package.json"
mkdir -p "$TMP_DIR/nv-monorepo/packages/app" && echo "20" > "$TMP_DIR/nv-monorepo/.nvmrc"
mkdir -p "$TMP_DIR/nv-monorepo-pkg/packages/app" && echo '{"engines":{"node":">=22"}}' > "$TMP_DIR/nv-monorepo-pkg/package.json"
mkdir -p "$TMP_DIR/nv-override"
echo "18" > "$TMP_DIR/nv-override/.nvmrc"
echo "FROM node:20" > "$TMP_DIR/nv-override/Dockerfile"
echo '{"engines":{"node":">=22"}}' > "$TMP_DIR/nv-override/package.json"
mkdir -p "$TMP_DIR/nv-empty"

# --- 1. Explicit Version Input Precedence ---
assert_node_version "24" "" "$TMP_DIR/nv-override" "$TMP_DIR/nv-override" "24|" "node_version: explicit input overrides .nvmrc, Dockerfile, and package.json"
assert_node_version "lts/*" "" "$TMP_DIR/nv-override" "$TMP_DIR/nv-override" "lts/*|" "node_version: explicit lts/* alias works"

# --- 2. Explicit Version File Input ---
assert_node_version "" ".nvmrc" "$TMP_DIR/nv-nvmrc" "$TMP_DIR/nv-nvmrc" "|$TMP_DIR/nv-nvmrc/.nvmrc" "node_version_file: explicit relative .nvmrc in DIR"
assert_node_version_fails "" "missing-file.txt" "$TMP_DIR/nv-empty" "$TMP_DIR/nv-empty" "node_version_file: fails fast if specified file does not exist"

# --- 3. Auto-discover .node-version or .nvmrc ---
assert_node_version "" "" "$TMP_DIR/nv-node-version" "$TMP_DIR/nv-node-version" "|$TMP_DIR/nv-node-version/.node-version" "auto-discover: finds .node-version in DIR"
assert_node_version "" "" "$TMP_DIR/nv-nvmrc" "$TMP_DIR/nv-nvmrc" "|$TMP_DIR/nv-nvmrc/.nvmrc" "auto-discover: finds .nvmrc in DIR"
assert_node_version "" "" "$TMP_DIR/nv-monorepo/packages/app" "$TMP_DIR/nv-monorepo" "|$TMP_DIR/nv-monorepo/.nvmrc" "auto-discover: finds .nvmrc in monorepo ROOT when DIR has none"

# --- 4. Auto-discover Dockerfile base image ---
assert_node_version "" "" "$TMP_DIR/nv-dockerfile-slim" "$TMP_DIR/nv-dockerfile-slim" "22|" "auto-discover: extracts Node version from node:22-bookworm-slim"
assert_node_version "" "" "$TMP_DIR/nv-dockerfile-distroless" "$TMP_DIR/nv-dockerfile-distroless" "20|" "auto-discover: extracts Node version from distroless nodejs20"
assert_node_version "" "" "$TMP_DIR/nv-dockerfile-fullver" "$TMP_DIR/nv-dockerfile-fullver" "24|" "auto-discover: extracts major version from node:24.20.0"
assert_node_version "" "" "$TMP_DIR/nv-dockerfile-commented" "$TMP_DIR/nv-dockerfile-commented" "22|" "auto-discover: ignores commented FROM and handles lowercase/platform flag"

# --- 5. Auto-discover package.json engines.node ---
assert_node_version "" "" "$TMP_DIR/nv-pkg-engines" "$TMP_DIR/nv-pkg-engines" "|$TMP_DIR/nv-pkg-engines/package.json" "auto-discover: delegates to package.json when engines.node is defined"
assert_node_version "" "" "$TMP_DIR/nv-monorepo-pkg/packages/app" "$TMP_DIR/nv-monorepo-pkg" "|$TMP_DIR/nv-monorepo-pkg/package.json" "auto-discover: finds root package.json engines in monorepo"

# --- 6. Fallback default when no indicators present ---
assert_node_version "" "" "$TMP_DIR/nv-pkg-no-engines" "$TMP_DIR/nv-pkg-no-engines" "24|" "fallback: defaults to 24 when package.json lacks engines.node"
assert_node_version "" "" "$TMP_DIR/nv-empty" "$TMP_DIR/nv-empty" "24|" "fallback: defaults to 24 when directory is empty"

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
