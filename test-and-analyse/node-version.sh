#!/usr/bin/env bash
# Node.js version determination and auto-detection for test-and-analyse.

set -euo pipefail

NODE_VER="${INPUT_NODE_VERSION:-}"
NODE_VER_FILE="${INPUT_NODE_VERSION_FILE:-}"
DIR="${INPUT_DIR:-.}"
ROOT="${INPUT_CHECKOUT_PATH:-.}"

OUTPUT_VERSION=""
OUTPUT_VERSION_FILE=""

# 1. Explicit version input takes highest precedence
if [ -n "$NODE_VER" ]; then
    OUTPUT_VERSION="$NODE_VER"
    echo "Using explicit node_version input: '$OUTPUT_VERSION'"

# 2. Explicit version-file input
elif [ -n "$NODE_VER_FILE" ]; then
    if [ -f "$NODE_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$NODE_VER_FILE"
    elif [ -f "$DIR/$NODE_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$DIR/$NODE_VER_FILE"
    elif [ -f "$ROOT/$NODE_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$ROOT/$NODE_VER_FILE"
    else
        echo "::error::Specified node_version_file '${NODE_VER_FILE}' not found." >&2
        exit 1
    fi
    echo "Using explicit node_version_file: '$OUTPUT_VERSION_FILE'"

else
    # 3. Auto-discover .node-version or .nvmrc in DIR, then ROOT
    for candidate in "$DIR/.node-version" "$DIR/.nvmrc" "$ROOT/.node-version" "$ROOT/.nvmrc"; do
        if [ -f "$candidate" ]; then
            OUTPUT_VERSION_FILE="$candidate"
            echo "Auto-discovered Node version file: '$OUTPUT_VERSION_FILE'"
            break
        fi
    done

    # 4. Auto-discover Dockerfile base image in DIR, then ROOT
    if [ -z "$OUTPUT_VERSION_FILE" ]; then
        for dockerfile in "$DIR/Dockerfile" "$ROOT/Dockerfile"; do
            if [ -f "$dockerfile" ]; then
                # Match e.g. FROM node:22-bookworm-slim, from --platform=linux/amd64 node:24.20.0, FROM gcr.io/distroless/nodejs20-debian12
                DETECTED=$(grep -im 1 -oE '^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?([^[:space:]]+/)?node(js)?:?[0-9]+' "$dockerfile" 2>/dev/null | grep -oE '[0-9]+$' || true)
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Node version '$OUTPUT_VERSION' from '$dockerfile'"
                    break
                fi
            fi
        done
    fi

    # 5. Check package.json engines.node in DIR, then ROOT
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for pkg_json in "$DIR/package.json" "$ROOT/package.json"; do
            if [ -f "$pkg_json" ]; then
                HAS_ENGINE=$(node -e 'try { const p = JSON.parse(require("node:fs").readFileSync(process.argv[1])); process.exit(p.engines?.node ? 0 : 1); } catch { process.exit(1); }' "$pkg_json" 2>/dev/null && echo "true" || echo "false")
                if [ "$HAS_ENGINE" == "true" ]; then
                    OUTPUT_VERSION_FILE="$pkg_json"
                    echo "Auto-discovered engines.node in '$OUTPUT_VERSION_FILE'"
                    break
                fi
            fi
        done
    fi

    # 6. Fallback default
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        OUTPUT_VERSION="24"
        echo "No Node version detected; falling back to default: '$OUTPUT_VERSION'"
    fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "node_version=$OUTPUT_VERSION" >> "$GITHUB_OUTPUT"
    echo "node_version_file=$OUTPUT_VERSION_FILE" >> "$GITHUB_OUTPUT"
fi
