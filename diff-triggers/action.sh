#!/usr/bin/env bash
# Forensic extraction of core logic from bcgov/action-diff-triggers baseline
# Migrated to mono-repo to support atomic, same-commit orchestration.

set -eo pipefail

TRIGGERS_STR="${INPUT_TRIGGERS:-}"
COMPARE_REF="${INPUT_REF:-}"
ANNOTATIONS_ENABLED="${INPUT_ANNOTATIONS:-true}"

# Always fire if triggers are omitted (matching original behavior)
if [[ -z "$TRIGGERS_STR" ]]; then
  echo "triggered=true" >> "$GITHUB_OUTPUT"
  if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
    echo "::notice title=Diff Triggers::✅ Diff Triggers fired. (triggers omitted — always fires)"
  fi
  exit 0
fi

# RESTORED: Parse triggers exactly like the original high-performance baseline
# Handles ('./path1/' './path2/') correctly
TRIGGERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TRIGGERS+=("$line")
done < <(grep -o "'[^']*'" <<< "$TRIGGERS_STR" | sed "s/'//g")

# Resolve the base ref to compare against
# PR events: default to base repo default branch if ref omitted
# Non-PR events: default to HEAD^ if ref omitted
if [[ -z "$COMPARE_REF" ]]; then
    if [[ "$GITHUB_EVENT_NAME" == "pull_request" ]]; then
        COMPARE_REF="$GITHUB_BASE_REF"
    else
        COMPARE_REF="HEAD^"
    fi
fi

# Analyze changes - match the original approach
MATCHED_LIST=""
TRIGGERED=false

for t in "${TRIGGERS[@]}"; do
    # Use name-only check (captures output to handle non-existent paths properly)
    DIFF_OUTPUT=$(git diff "$COMPARE_REF" --name-only -- "$t" 2>/dev/null || true)
    if [[ -n "$DIFF_OUTPUT" ]]; then
        TRIGGERED=true
        MATCHED_LIST="$MATCHED_LIST $t"
    fi
done

if [[ "$TRIGGERED" == "true" ]]; then
    echo "triggered=true" >> "$GITHUB_OUTPUT"
    if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
        echo "::notice title=Diff Triggers::✅ Diff Triggers fired. (Matched: $MATCHED_LIST)"
    fi
else
    echo "triggered=false" >> "$GITHUB_OUTPUT"
    if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
        echo "::notice title=Diff Triggers::ℹ️ Diff Triggers not fired."
    fi
fi

echo "base_ref=${COMPARE_REF}" >> "$GITHUB_OUTPUT"
echo "head_ref=${GITHUB_REF}" >> "$GITHUB_OUTPUT"
