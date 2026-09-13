#!/usr/bin/env bash
# Python version determination and auto-detection for test-and-analyse.

set -euo pipefail

PY_VER="${INPUT_PYTHON_VERSION:-}"
PY_VER_FILE="${INPUT_PYTHON_VERSION_FILE:-}"
DIR="${INPUT_DIR:-.}"
ROOT="${INPUT_CHECKOUT_PATH:-.}"

OUTPUT_VERSION=""
OUTPUT_VERSION_FILE=""

extract_py_from_spec() {
    # Prefer a lower bound so "<3.13,>=3.10" / "^3.11" -> 3.10 / 3.11, not 3.13
    local spec="$1"
    local from_min
    from_min=$(echo "$spec" | grep -oE '(>=|\^|~=)[[:space:]]*[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    if [ -n "$from_min" ]; then
        echo "$from_min"
        return
    fi
    # Bare "3.12" (no comparison)
    echo "$spec" | grep -oE '(^|[[:space:]])[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true
}

# 1. Explicit version input
if [ -n "$PY_VER" ]; then
    OUTPUT_VERSION="$PY_VER"
    echo "Using explicit python_version input: '$OUTPUT_VERSION'"

# 2. Explicit version-file input
elif [ -n "$PY_VER_FILE" ]; then
    if [ -f "$PY_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$PY_VER_FILE"
    elif [ -f "$DIR/$PY_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$DIR/$PY_VER_FILE"
    elif [ -f "$ROOT/$PY_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$ROOT/$PY_VER_FILE"
    else
        echo "::error::Specified python_version_file '${PY_VER_FILE}' not found." >&2
        exit 1
    fi
    echo "Using explicit python_version_file: '$OUTPUT_VERSION_FILE'"

else
    # 3. .python-version in DIR, then ROOT
    for candidate in "$DIR/.python-version" "$ROOT/.python-version"; do
        if [ -f "$candidate" ]; then
            OUTPUT_VERSION_FILE="$candidate"
            echo "Auto-discovered Python version file: '$OUTPUT_VERSION_FILE'"
            break
        fi
    done

    # 4. pyproject.toml — delegate requires-python to setup-python; Poetry python = extracted
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for pyproject in "$DIR/pyproject.toml" "$ROOT/pyproject.toml"; do
            if [ -f "$pyproject" ]; then
                if grep -qE '^[[:space:]]*requires-python[[:space:]]*=' "$pyproject"; then
                    OUTPUT_VERSION_FILE="$pyproject"
                    echo "Auto-discovered Python version file: '$OUTPUT_VERSION_FILE'"
                    break
                fi
                spec=$(awk '
                    /^\[tool\.poetry\.dependencies\]/ { in_deps=1; next }
                    /^\[/ { in_deps=0 }
                    in_deps && /^[[:space:]]*python[[:space:]]*=/ {
                        sub(/^[^=]*=[[:space:]]*/, "")
                        gsub(/["'\'']/, "")
                        print
                        exit
                    }
                ' "$pyproject" || true)
                DETECTED=$(extract_py_from_spec "$spec")
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Python version '$OUTPUT_VERSION' from '$pyproject'"
                    break
                fi
            fi
        done
    fi

    # 5. Dockerfile / Containerfile FROM python:X.Y
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for dockerfile in "$DIR/Dockerfile" "$DIR/Containerfile" "$ROOT/Dockerfile" "$ROOT/Containerfile"; do
            if [ -f "$dockerfile" ]; then
                DETECTED=$(grep -im 1 -oE '^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?([^[:space:]]+/)?python:[0-9]+(\.[0-9]+)?' "$dockerfile" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?$' || true)
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Python version '$OUTPUT_VERSION' from '$dockerfile'"
                    break
                fi
            fi
        done
    fi

    # 6. Pipfile [requires] python_version — real assignment only
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for pipfile in "$DIR/Pipfile" "$ROOT/Pipfile"; do
            if [ -f "$pipfile" ]; then
                spec=$(awk '
                    /^\[requires\]/ { in_req=1; next }
                    /^\[/ { in_req=0 }
                    in_req && /^[[:space:]]*python_version[[:space:]]*=/ {
                        gsub(/["'\'']/, "")
                        sub(/^[^=]*=[[:space:]]*/, "")
                        print
                        exit
                    }
                ' "$pipfile" || true)
                DETECTED=$(extract_py_from_spec "$spec")
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Python version '$OUTPUT_VERSION' from '$pipfile'"
                    break
                fi
            fi
        done
    fi

    # 7. Fallback
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        OUTPUT_VERSION="3.12"
        echo "No Python version detected; falling back to default: '$OUTPUT_VERSION'"
    fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "python_version=$OUTPUT_VERSION" >> "$GITHUB_OUTPUT"
    echo "python_version_file=$OUTPUT_VERSION_FILE" >> "$GITHUB_OUTPUT"
fi
