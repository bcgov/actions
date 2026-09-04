#!/usr/bin/env bash
# Cache detection and validation for test-and-analyse.

set -euo pipefail

CACHE_VAL="${INPUT_CACHE:-}"
LANG="${INPUT_LANGUAGE:-node}"
DIR="${INPUT_DIR:-.}"
ROOT="${INPUT_CHECKOUT_PATH:-.}"

VAL="${CACHE_VAL,,}"
RESULT=""

if [ "$VAL" == "none" ]; then
    RESULT=""
elif [ -n "$VAL" ]; then
    case "$LANG" in
        node)
            case "$VAL" in
                npm|yarn|pnpm) RESULT="$VAL" ;;
                *) echo "::error::Invalid cache value '${CACHE_VAL}' for language '${LANG}'. Allowed values: npm, yarn, pnpm, none." >&2; exit 1 ;;
            esac
            ;;
        java)
            case "$VAL" in
                maven|gradle|sbt) RESULT="$VAL" ;;
                *) echo "::error::Invalid cache value '${CACHE_VAL}' for language '${LANG}'. Allowed values: maven, gradle, sbt, none." >&2; exit 1 ;;
            esac
            ;;
        python)
            case "$VAL" in
                pip|poetry|pipenv) RESULT="$VAL" ;;
                *) echo "::error::Invalid cache value '${CACHE_VAL}' for language '${LANG}'. Allowed values: pip, poetry, pipenv, none." >&2; exit 1 ;;
            esac
            ;;
        *)
            echo "::error::Unsupported language: $LANG" >&2; exit 1 ;;
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
            echo "::error::Unsupported language: $LANG" >&2; exit 1 ;;
    esac
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "cache=$RESULT" >> "$GITHUB_OUTPUT"
fi
echo "Determined cache type: '$RESULT' for language: $LANG (input: '$CACHE_VAL')"
