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
    echo "$1" | grep -oE '[0-9]+' | head -1 || true
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
    # 3. .java-version, .sdkmanrc, .tool-versions in DIR then ROOT
    for candidate in "$DIR/.java-version" "$DIR/.sdkmanrc" "$DIR/.tool-versions" \
                     "$ROOT/.java-version" "$ROOT/.sdkmanrc" "$ROOT/.tool-versions"; do
        if [ -f "$candidate" ]; then
            base=$(basename "$candidate")
            if [ "$base" = ".java-version" ] || [ "$base" = ".tool-versions" ]; then
                OUTPUT_VERSION_FILE="$candidate"
                echo "Auto-discovered Java version file: '$OUTPUT_VERSION_FILE'"
                break
            fi
            # .sdkmanrc: java=21.0.2-tem
            spec=$(grep -E '^[[:space:]]*java=' "$candidate" | head -1 | cut -d= -f2- || true)
            DETECTED=$(extract_java_major "$spec")
            if [ -n "$DETECTED" ]; then
                OUTPUT_VERSION="$DETECTED"
                echo "Auto-discovered Java version '$OUTPUT_VERSION' from '$candidate'"
                break
            fi
        fi
    done

    # 4. Maven / Gradle manifests
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for pom in "$DIR/pom.xml" "$ROOT/pom.xml"; do
            if [ -f "$pom" ]; then
                spec=$(grep -E '<(java.version|maven.compiler.(release|target|source))>' "$pom" | head -1 | sed -E 's/.*>([^<]+)<.*/\1/' || true)
                DETECTED=$(extract_java_major "$spec")
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Java version '$OUTPUT_VERSION' from '$pom'"
                    break
                fi
            fi
        done
    fi
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for gradle in "$DIR/build.gradle" "$DIR/build.gradle.kts" "$ROOT/build.gradle" "$ROOT/build.gradle.kts"; do
            if [ -f "$gradle" ]; then
                spec=$(grep -E 'jvmToolchain|sourceCompatibility|targetCompatibility|JavaVersion' "$gradle" | head -1 || true)
                DETECTED=$(extract_java_major "$spec")
                if [ -n "$DETECTED" ]; then
                    OUTPUT_VERSION="$DETECTED"
                    echo "Auto-discovered Java version '$OUTPUT_VERSION' from '$gradle'"
                    break
                fi
            fi
        done
    fi

    # 5. Dockerfile / Containerfile
    if [ -z "$OUTPUT_VERSION" ] && [ -z "$OUTPUT_VERSION_FILE" ]; then
        for dockerfile in "$DIR/Dockerfile" "$DIR/Containerfile" "$ROOT/Dockerfile" "$ROOT/Containerfile"; do
            if [ -f "$dockerfile" ]; then
                # eclipse-temurin:21-jdk, openjdk:17-slim, amazoncorretto:21, ibm-semeru-runtimes:open-17
                line=$(grep -im 1 -E '^[[:space:]]*FROM[[:space:]]+' "$dockerfile" || true)
                DETECTED=$(echo "$line" | grep -oE '(temurin|openjdk|amazoncorretto|semeru-runtimes:open-)[^[:space:]]*' | grep -oE '[0-9]+' | head -1 || true)
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
