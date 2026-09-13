#!/usr/bin/env bash
# Java version determination and auto-detection for test-and-analyse.

set -euo pipefail

JAVA_VER="${INPUT_JAVA_VERSION:-}"
JAVA_VER_FILE="${INPUT_JAVA_VERSION_FILE:-}"
DIR="${INPUT_DIR:-.}"
ROOT="${INPUT_CHECKOUT_PATH:-.}"

OUTPUT_VERSION=""
OUTPUT_VERSION_FILE=""

extract_java_major() {
    local s="$1"
    # Legacy Java 8: 1.8 / 1.8.0 / VERSION_1_8
    if echo "$s" | grep -qE '(^|[^0-9])1[._]8([^0-9]|$)'; then
        echo 8
        return
    fi
    echo "$s" | grep -oE '[0-9]+' | head -1 || true
}

# 1. Explicit version input
if [ -n "$JAVA_VER" ]; then
    OUTPUT_VERSION="$JAVA_VER"
    echo "Using explicit java_version input: '$OUTPUT_VERSION'"

# 2. Explicit version-file input
elif [ -n "$JAVA_VER_FILE" ]; then
    if [ -f "$JAVA_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$JAVA_VER_FILE"
    elif [ -f "$DIR/$JAVA_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$DIR/$JAVA_VER_FILE"
    elif [ -f "$ROOT/$JAVA_VER_FILE" ]; then
        OUTPUT_VERSION_FILE="$ROOT/$JAVA_VER_FILE"
    else
        echo "::error::Specified java_version_file '${JAVA_VER_FILE}' not found." >&2
        exit 1
    fi
    echo "Using explicit java_version_file: '$OUTPUT_VERSION_FILE'"

else
    # 3. Version files in DIR then ROOT. .tool-versions / .sdkmanrc only if they name java.
    for candidate in "$DIR/.java-version" "$DIR/.sdkmanrc" "$DIR/.tool-versions" \
                     "$ROOT/.java-version" "$ROOT/.sdkmanrc" "$ROOT/.tool-versions"; do
        if [ ! -f "$candidate" ]; then
            continue
        fi
        base=$(basename "$candidate")
        if [ "$base" = ".java-version" ]; then
            OUTPUT_VERSION_FILE="$candidate"
            echo "Auto-discovered Java version file: '$OUTPUT_VERSION_FILE'"
            break
        fi
        if [ "$base" = ".tool-versions" ]; then
            if grep -qE '^[[:space:]]*java[[:space:]]+' "$candidate"; then
                OUTPUT_VERSION_FILE="$candidate"
                echo "Auto-discovered Java version file: '$OUTPUT_VERSION_FILE'"
                break
            fi
            continue
        fi
        if [ "$base" = ".sdkmanrc" ]; then
            if grep -qE '^[[:space:]]*java=' "$candidate"; then
                OUTPUT_VERSION_FILE="$candidate"
                echo "Auto-discovered Java version file: '$OUTPUT_VERSION_FILE'"
                break
            fi
        fi
    done

    # 4. Maven / Gradle manifests
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for pom in "$DIR/pom.xml" "$ROOT/pom.xml"; do
            if [ -f "$pom" ]; then
                while IFS= read -r spec; do
                    DETECTED=$(extract_java_major "$spec")
                    if [ -n "$DETECTED" ]; then
                        OUTPUT_VERSION="$DETECTED"
                        echo "Auto-discovered Java version '$OUTPUT_VERSION' from '$pom'"
                        break
                    fi
                done < <(grep -E '<(java.version|maven.compiler.(release|target|source))>' "$pom" | sed -E 's/.*>([^<]+)<.*/\1/' || true)
                if [ -n "$OUTPUT_VERSION" ]; then
                    break
                fi
            fi
        done
    fi
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for gradle in "$DIR/build.gradle" "$DIR/build.gradle.kts" "$ROOT/build.gradle" "$ROOT/build.gradle.kts"; do
            if [ -f "$gradle" ]; then
                while IFS= read -r spec; do
                    DETECTED=$(extract_java_major "$spec")
                    if [ -n "$DETECTED" ]; then
                        OUTPUT_VERSION="$DETECTED"
                        echo "Auto-discovered Java version '$OUTPUT_VERSION' from '$gradle'"
                        break
                    fi
                done < <(grep -E 'jvmToolchain|sourceCompatibility|targetCompatibility|JavaVersion' "$gradle" || true)
                if [ -n "$OUTPUT_VERSION" ]; then
                    break
                fi
            fi
        done
    fi

    # 5. Dockerfile / Containerfile — first Java image FROM, not the first FROM
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for dockerfile in "$DIR/Dockerfile" "$DIR/Containerfile" "$ROOT/Dockerfile" "$ROOT/Containerfile"; do
            if [ -f "$dockerfile" ]; then
                line=$(grep -im 1 -E '^[[:space:]]*FROM[[:space:]].*(temurin|openjdk|amazoncorretto|semeru)' "$dockerfile" || true)
                DETECTED=$(extract_java_major "$line")
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Java version '$OUTPUT_VERSION' from '$dockerfile'"
                    break
                fi
            fi
        done
    fi

    # 6. Fallback
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        OUTPUT_VERSION="21"
        echo "No Java version detected; falling back to default: '$OUTPUT_VERSION'"
    fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "java_version=$OUTPUT_VERSION" >> "$GITHUB_OUTPUT"
    echo "java_version_file=$OUTPUT_VERSION_FILE" >> "$GITHUB_OUTPUT"
fi
