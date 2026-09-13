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


# ==============================================================================
# Python Version Determination & Auto-Detection Tests
# ==============================================================================
PYTHON_VERSION_SCRIPT="${SCRIPT_DIR}/../python-version.sh"

determine_python_version() {
    local VER="$1"
    local VER_FILE="$2"
    local DIR="${3:-.}"
    local ROOT="${4:-.}"
    local out_file
    out_file="$(mktemp)"
    if GITHUB_OUTPUT="$out_file" \
       INPUT_PYTHON_VERSION="$VER" \
       INPUT_PYTHON_VERSION_FILE="$VER_FILE" \
       INPUT_DIR="$DIR" \
       INPUT_CHECKOUT_PATH="$ROOT" \
       bash "$PYTHON_VERSION_SCRIPT" >/dev/null 2>&1; then
        local ver_out="" file_out=""
        if grep -q '^python_version=' "$out_file"; then
            ver_out="$(grep '^python_version=' "$out_file" | cut -d= -f2-)"
        fi
        if grep -q '^python_version_file=' "$out_file"; then
            file_out="$(grep '^python_version_file=' "$out_file" | cut -d= -f2-)"
        fi
        rm -f "$out_file"
        printf '%s|%s' "$ver_out" "$file_out"
        return 0
    else
        rm -f "$out_file"
        return 1
    fi
}

assert_python_version() {
    local actual
    actual="$(determine_python_version "$1" "$2" "$3" "$4")"
    if [[ "$actual" == "$5" ]]; then
        echo "✓ $6"
        passed=$((passed + 1))
    else
        echo "✗ $6"
        echo "  Expected: '$5'"
        echo "  Actual:   '$actual'"
        failed=$((failed + 1))
    fi
}

assert_python_version_fails() {
    if ! determine_python_version "$1" "$2" "$3" "$4" 2>/dev/null; then
        echo "✓ $5"
        passed=$((passed + 1))
    else
        echo "✗ $5"
        echo "  Expected failure, but command succeeded"
        failed=$((failed + 1))
    fi
}

echo ""
echo "Running python-version auto-detection unit tests..."

mkdir -p "$TMP_DIR/pv-dot" && echo "3.11" > "$TMP_DIR/pv-dot/.python-version"
mkdir -p "$TMP_DIR/pv-pep" && printf '[project]\nrequires-python = ">=3.10,<4"\n' > "$TMP_DIR/pv-pep/pyproject.toml"
mkdir -p "$TMP_DIR/pv-poetry" && printf '[tool.poetry.dependencies]\npython = "^3.11"\n' > "$TMP_DIR/pv-poetry/pyproject.toml"
mkdir -p "$TMP_DIR/pv-docker" && echo "FROM python:3.13-slim" > "$TMP_DIR/pv-docker/Dockerfile"
mkdir -p "$TMP_DIR/pv-pipfile" && printf '[requires]\npython_version = "3.9"\n' > "$TMP_DIR/pv-pipfile/Pipfile"
mkdir -p "$TMP_DIR/pv-mono/packages/app" && echo "3.12" > "$TMP_DIR/pv-mono/.python-version"
mkdir -p "$TMP_DIR/pv-override"
echo "3.9" > "$TMP_DIR/pv-override/.python-version"
echo "FROM python:3.8" > "$TMP_DIR/pv-override/Dockerfile"
mkdir -p "$TMP_DIR/pv-empty"

assert_python_version "3.14" "" "$TMP_DIR/pv-override" "$TMP_DIR/pv-override" "3.14|" "python_version: explicit input overrides files"
assert_python_version "" ".python-version" "$TMP_DIR/pv-dot" "$TMP_DIR/pv-dot" "|$TMP_DIR/pv-dot/.python-version" "python_version_file: explicit .python-version"
assert_python_version_fails "" "missing.txt" "$TMP_DIR/pv-empty" "$TMP_DIR/pv-empty" "python_version_file: fails fast if missing"
assert_python_version "" "" "$TMP_DIR/pv-dot" "$TMP_DIR/pv-dot" "|$TMP_DIR/pv-dot/.python-version" "auto-discover: .python-version in DIR"
assert_python_version "" "" "$TMP_DIR/pv-mono/packages/app" "$TMP_DIR/pv-mono" "|$TMP_DIR/pv-mono/.python-version" "auto-discover: .python-version in ROOT"
assert_python_version "" "" "$TMP_DIR/pv-pep" "$TMP_DIR/pv-pep" "|$TMP_DIR/pv-pep/pyproject.toml" "auto-discover: delegates requires-python pyproject.toml to setup-python"
assert_python_version "" "" "$TMP_DIR/pv-poetry" "$TMP_DIR/pv-poetry" "3.11|" "auto-discover: Poetry python constraint"
assert_python_version "" "" "$TMP_DIR/pv-docker" "$TMP_DIR/pv-docker" "3.13|" "auto-discover: Dockerfile python:3.13-slim"
assert_python_version "" "" "$TMP_DIR/pv-pipfile" "$TMP_DIR/pv-pipfile" "3.9|" "auto-discover: Pipfile python_version"
assert_python_version "" "" "$TMP_DIR/pv-empty" "$TMP_DIR/pv-empty" "3.12|" "fallback: defaults to 3.12"

# ==============================================================================
# Java Version Determination & Auto-Detection Tests
# ==============================================================================
JAVA_VERSION_SCRIPT="${SCRIPT_DIR}/../java-version.sh"

determine_java_version() {
    local VER="$1"
    local VER_FILE="$2"
    local DIR="${3:-.}"
    local ROOT="${4:-.}"
    local out_file
    out_file="$(mktemp)"
    if GITHUB_OUTPUT="$out_file" \
       INPUT_JAVA_VERSION="$VER" \
       INPUT_JAVA_VERSION_FILE="$VER_FILE" \
       INPUT_DIR="$DIR" \
       INPUT_CHECKOUT_PATH="$ROOT" \
       bash "$JAVA_VERSION_SCRIPT" >/dev/null 2>&1; then
        local ver_out="" file_out=""
        if grep -q '^java_version=' "$out_file"; then
            ver_out="$(grep '^java_version=' "$out_file" | cut -d= -f2-)"
        fi
        if grep -q '^java_version_file=' "$out_file"; then
            file_out="$(grep '^java_version_file=' "$out_file" | cut -d= -f2-)"
        fi
        rm -f "$out_file"
        printf '%s|%s' "$ver_out" "$file_out"
        return 0
    else
        rm -f "$out_file"
        return 1
    fi
}

assert_java_version() {
    local actual
    actual="$(determine_java_version "$1" "$2" "$3" "$4")"
    if [[ "$actual" == "$5" ]]; then
        echo "✓ $6"
        passed=$((passed + 1))
    else
        echo "✗ $6"
        echo "  Expected: '$5'"
        echo "  Actual:   '$actual'"
        failed=$((failed + 1))
    fi
}

assert_java_version_fails() {
    if ! determine_java_version "$1" "$2" "$3" "$4" 2>/dev/null; then
        echo "✓ $5"
        passed=$((passed + 1))
    else
        echo "✗ $5"
        echo "  Expected failure, but command succeeded"
        failed=$((failed + 1))
    fi
}

echo ""
echo "Running java-version auto-detection unit tests..."

mkdir -p "$TMP_DIR/jv-dot" && echo "17" > "$TMP_DIR/jv-dot/.java-version"
mkdir -p "$TMP_DIR/jv-sdkman" && echo "java=21.0.2-tem" > "$TMP_DIR/jv-sdkman/.sdkmanrc"
mkdir -p "$TMP_DIR/jv-tools" && echo "java 17.0.11-tem" > "$TMP_DIR/jv-tools/.tool-versions"
mkdir -p "$TMP_DIR/jv-pom" && printf '<project><properties><java.version>17</java.version></properties></project>\n' > "$TMP_DIR/jv-pom/pom.xml"
mkdir -p "$TMP_DIR/jv-gradle" && echo 'java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }' > "$TMP_DIR/jv-gradle/build.gradle"
mkdir -p "$TMP_DIR/jv-docker" && echo "FROM eclipse-temurin:21-jdk" > "$TMP_DIR/jv-docker/Dockerfile"
mkdir -p "$TMP_DIR/jv-mono/packages/app" && echo "17" > "$TMP_DIR/jv-mono/.java-version"
mkdir -p "$TMP_DIR/jv-override"
echo "11" > "$TMP_DIR/jv-override/.java-version"
echo "FROM eclipse-temurin:17" > "$TMP_DIR/jv-override/Dockerfile"
mkdir -p "$TMP_DIR/jv-empty"

assert_java_version "21" "" "$TMP_DIR/jv-override" "$TMP_DIR/jv-override" "21|" "java_version: explicit input overrides files"
assert_java_version "" ".java-version" "$TMP_DIR/jv-dot" "$TMP_DIR/jv-dot" "|$TMP_DIR/jv-dot/.java-version" "java_version_file: explicit .java-version"
assert_java_version_fails "" "missing.txt" "$TMP_DIR/jv-empty" "$TMP_DIR/jv-empty" "java_version_file: fails fast if missing"
assert_java_version "" "" "$TMP_DIR/jv-dot" "$TMP_DIR/jv-dot" "|$TMP_DIR/jv-dot/.java-version" "auto-discover: .java-version in DIR"
assert_java_version "" "" "$TMP_DIR/jv-mono/packages/app" "$TMP_DIR/jv-mono" "|$TMP_DIR/jv-mono/.java-version" "auto-discover: .java-version in ROOT"
assert_java_version "" "" "$TMP_DIR/jv-sdkman" "$TMP_DIR/jv-sdkman" "|$TMP_DIR/jv-sdkman/.sdkmanrc" "auto-discover: .sdkmanrc passed through as version file"
assert_java_version "" "" "$TMP_DIR/jv-tools" "$TMP_DIR/jv-tools" "|$TMP_DIR/jv-tools/.tool-versions" "auto-discover: .tool-versions"
assert_java_version "" "" "$TMP_DIR/jv-pom" "$TMP_DIR/jv-pom" "17|" "auto-discover: pom.xml java.version"
assert_java_version "" "" "$TMP_DIR/jv-gradle" "$TMP_DIR/jv-gradle" "21|" "auto-discover: Gradle jvmToolchain"
assert_java_version "" "" "$TMP_DIR/jv-docker" "$TMP_DIR/jv-docker" "21|" "auto-discover: Dockerfile eclipse-temurin:21"
assert_java_version "" "" "$TMP_DIR/jv-empty" "$TMP_DIR/jv-empty" "21|" "fallback: defaults to 21"

# Review follow-ups
mkdir -p "$TMP_DIR/pv-constraint" && printf '[project]\nrequires-python = "<3.13,>=3.10"\n' > "$TMP_DIR/pv-constraint/pyproject.toml"
mkdir -p "$TMP_DIR/pv-pipfile-comment" && printf '[requires]\n# python_version = "3.9"\npython_version = "3.12"\n' > "$TMP_DIR/pv-pipfile-comment/Pipfile"
mkdir -p "$TMP_DIR/jv-legacy-pom" && printf '<project><properties><maven.compiler.source>1.8</maven.compiler.source></properties></project>\n' > "$TMP_DIR/jv-legacy-pom/pom.xml"
mkdir -p "$TMP_DIR/jv-legacy-gradle" && echo 'sourceCompatibility = JavaVersion.VERSION_1_8' > "$TMP_DIR/jv-legacy-gradle/build.gradle"
mkdir -p "$TMP_DIR/jv-tools-node-only" && echo "nodejs 22.14.0" > "$TMP_DIR/jv-tools-node-only/.tool-versions" && printf '<project><properties><java.version>17</java.version></properties></project>\n' > "$TMP_DIR/jv-tools-node-only/pom.xml"
mkdir -p "$TMP_DIR/jv-pom-prop" && printf '<project><properties><maven.compiler.release>${java.version}</maven.compiler.release><java.version>17</java.version></properties></project>\n' > "$TMP_DIR/jv-pom-prop/pom.xml"
mkdir -p "$TMP_DIR/jv-gradle-import" && printf 'import org.gradle.api.JavaVersion\nsourceCompatibility = JavaVersion.VERSION_17\n' > "$TMP_DIR/jv-gradle-import/build.gradle.kts"
mkdir -p "$TMP_DIR/jv-docker-multistage" && printf 'FROM alpine AS tools\nFROM eclipse-temurin:17-jdk\n' > "$TMP_DIR/jv-docker-multistage/Dockerfile"

assert_python_version "" "" "$TMP_DIR/pv-constraint" "$TMP_DIR/pv-constraint" "|$TMP_DIR/pv-constraint/pyproject.toml" "auto-discover: upper-bound-first requires-python still delegated"
assert_python_version "" "" "$TMP_DIR/pv-pipfile-comment" "$TMP_DIR/pv-pipfile-comment" "3.12|" "auto-discover: Pipfile ignores commented python_version"
assert_java_version "" "" "$TMP_DIR/jv-legacy-pom" "$TMP_DIR/jv-legacy-pom" "8|" "auto-discover: Maven 1.8 is Java 8"
assert_java_version "" "" "$TMP_DIR/jv-legacy-gradle" "$TMP_DIR/jv-legacy-gradle" "8|" "auto-discover: VERSION_1_8 is Java 8"
assert_java_version "" "" "$TMP_DIR/jv-tools-node-only" "$TMP_DIR/jv-tools-node-only" "17|" "auto-discover: .tool-versions without java falls through to pom"
assert_java_version "" "" "$TMP_DIR/jv-pom-prop" "$TMP_DIR/jv-pom-prop" "17|" "auto-discover: skips POM property placeholder then finds 17"
assert_java_version "" "" "$TMP_DIR/jv-gradle-import" "$TMP_DIR/jv-gradle-import" "17|" "auto-discover: skips JavaVersion import then finds VERSION_17"
assert_java_version "" "" "$TMP_DIR/jv-docker-multistage" "$TMP_DIR/jv-docker-multistage" "17|" "auto-discover: skips non-Java FROM then finds temurin:17"

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
