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
if [[ -z "$COMPARE_REF" ]]; then
    if [[ "$GITHUB_EVENT_NAME" == "pull_request" ]]; then
        # Use PR base if available (matching ancestor behavior)
        COMPARE_REF="origin/$GITHUB_BASE_REF"
    else
        COMPARE_REF="HEAD~1"
    fi
fi

# Analyze changes
MATCHED_LIST=""
TRIGGERED=false

for t in "${TRIGGERS[@]}"; do
    # Use name-only check for performance parity
    if git diff --quiet "$COMPARE_REF" HEAD -- "$t"; then
        continue
    else
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
