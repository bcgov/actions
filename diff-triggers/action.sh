#!/usr/bin/env bash
# Forensic extraction of core logic from bcgov/action-diff-triggers baseline
# Migrated to mono-repo to support atomic, same-commit orchestration.

set -eo pipefail

TRIGGERS_STR="${INPUT_TRIGGERS:-}"
COMPARE_REF="${INPUT_REF:-}"
ANNOTATIONS_ENABLED="${INPUT_ANNOTATIONS:-true}"

if [[ -z "$TRIGGERS_STR" ]]; then
  echo "::error::No triggers provided. Please set the 'triggers' input."
  exit 1
fi

# Resolve the base ref to compare against
if [[ -z "$COMPARE_REF" ]]; then
    # Default behavior matches original action-diff-triggers
    if [[ "$GITHUB_EVENT_NAME" == "pull_request" ]]; then
        COMPARE_REF="origin/$GITHUB_BASE_REF"
        REF_SOURCE="pull_request.base_ref"
    else
        COMPARE_REF="HEAD~1"
        REF_SOURCE="HEAD~1 (default)"
    fi
else
    REF_SOURCE="input.ref"
fi

echo "Group: Diff Triggers — Analyzing | $GITHUB_REPOSITORY"
echo "  Triggers:     $TRIGGERS_STR"
echo "  Comparing to: $COMPARE_REF"
echo "  Ref source:   $REF_SOURCE"

# Split triggers and check for changes
MATCHED_LIST=""
IFS=',' read -ra ADDR <<< "$TRIGGERS_STR"
for trigger in "${ADDR[@]}"; do
    trigger=$(echo "$trigger" | xargs) # trim
    if git diff --quiet "$COMPARE_REF" HEAD -- "$trigger"; then
        continue
    else
        MATCHED_LIST="${MATCHED_LIST}${trigger} "
    fi
done

if [[ -n "$MATCHED_LIST" ]]; then
    echo "  Matched:      $MATCHED_LIST"
    if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
        echo "::notice title=Diff Triggers::✅ Diff Triggers fired. ($GITHUB_REPOSITORY)"
    fi
    echo "triggered=true" >> "$GITHUB_OUTPUT"
    # Exporting refs for forensic walker support (PR #13 prep)
    echo "base_ref=$(git rev-parse $COMPARE_REF)" >> "$GITHUB_OUTPUT"
    echo "head_ref=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
else
    if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
        echo "::notice title=Diff Triggers::ℹ️ Diff Triggers not fired. ($GITHUB_REPOSITORY)"
    fi
    echo "triggered=false" >> "$GITHUB_OUTPUT"
fi