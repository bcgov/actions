#!/bin/bash
set -euo pipefail

# Helper functions for consistency across all actions
function log_debug() {
  if [ "${INPUT_DEBUG:-}" == "true" ]; then
    echo "DEBUG: $1"
  fi
}

# 1. Inputs & Context
# TRIGGERS: Paths to check (e.g. './backend/' './frontend/')
# REF: The reference to compare against
# ANNOTATIONS: Boolean to emit notices
ANNOTATIONS_ENABLED="${INPUT_ANNOTATIONS:-true}"
ANNOTATIONS_ENABLED="$(echo "$ANNOTATIONS_ENABLED" | tr '[:upper:]' '[:lower:]')"
CALLER_CONTEXT="[${GITHUB_WORKFLOW:-unknown} / ${GITHUB_JOB:-unknown}]"

log_debug "Action started: diff-triggers"
log_debug "Triggers: ${INPUT_TRIGGERS:-}"
log_debug "Ref: ${INPUT_REF:-}"

# Always fire if triggers are omitted
if [ -z "${INPUT_TRIGGERS:-}" ]; then
  echo "::group::Diff Triggers — ✅ TRIGGERED | ${GITHUB_REPOSITORY} $CALLER_CONTEXT"
  echo "  Triggers: (omitted — always fires)"
  echo "::endgroup::"
  if [ "$ANNOTATIONS_ENABLED" == "true" ]; then
    echo "::notice title=Diff Triggers::✅ Diff Triggers fired. (${GITHUB_REPOSITORY})"
  fi
  echo "triggered=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

# 2. Parse triggers input (properly handles quoted strings with spaces)
TRIGGERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TRIGGERS+=("$line")
done < <(grep -o "'[^']*'" <<< "${INPUT_TRIGGERS}" | sed "s/'//g")

# 3. Determine Base Reference
# For PRs: default to base repo default branch if ref omitted
# For pushes: default to HEAD^ if ref omitted
BASE_REF="${INPUT_REF:-}"
if [ -z "$BASE_REF" ]; then
    if [ -n "${GITHUB_BASE_REF:-}" ]; then
        BASE_REF="${GITHUB_BASE_REF}"
    else
        BASE_REF="HEAD^"
    fi
fi
log_debug "Determined BASE_REF: $BASE_REF"

# 4. Git Remote & Fetch
BASE_REMOTE_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
if git remote get-url base >/dev/null 2>&1; then
  git remote set-url base "$BASE_REMOTE_URL"
else
  git remote add base "$BASE_REMOTE_URL"
fi

# If BASE_REF starts with HEAD, it's a local ref - use it directly
if [[ "$BASE_REF" == HEAD* ]]; then
  COMPARE_REF="$BASE_REF"
else
  log_debug "Fetching remote ref: $BASE_REF"
  git fetch base "$BASE_REF" --depth=1 || git fetch base "$BASE_REF"
  COMPARE_REF="base/$BASE_REF"
fi

# 5. Check all triggers
TRIGGERED=false
MATCHED_TRIGGERS=()
DETAILS_LOG=""

for t in "${TRIGGERS[@]}"; do
  log_debug "Checking trigger: $t"
  # Use git diff --name-only to find changed files under the path
  DIFF_OUTPUT=$(git diff "$COMPARE_REF" --name-only -- "$t" || true)
  if [[ -n "$DIFF_OUTPUT" ]]; then
    TRIGGERED=true
    MATCHED_TRIGGERS+=("$t")
    DETAILS_LOG+="  ✔ '$t'"$'\n'
    while IFS= read -r f; do
      DETAILS_LOG+="      $f"$'\n'
    done <<< "$DIFF_OUTPUT"
  else
    DETAILS_LOG+="  ✘ '$t'"$'\n'
  fi
done

# 6. Report Results
if [[ "$TRIGGERED" == "true" ]]; then
  MATCHED_LIST=$(IFS=', '; echo "${MATCHED_TRIGGERS[*]}")
  echo "::group::Diff Triggers — ✅ TRIGGERED | ${GITHUB_REPOSITORY} $CALLER_CONTEXT"
  echo "  Triggers:     ${INPUT_TRIGGERS}"
  echo "  Comparing to: $COMPARE_REF"
  echo "  Matched:      $MATCHED_LIST"
  echo ""
  echo -e "$DETAILS_LOG"
  echo "::endgroup::"
  if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
    echo "::notice title=Diff Triggers::✅ Diff Triggers fired. (${GITHUB_REPOSITORY})"
  fi
  echo "triggered=true" >> "$GITHUB_OUTPUT"
else
  echo "::group::Diff Triggers — ⊘ NOT TRIGGERED | ${GITHUB_REPOSITORY} $CALLER_CONTEXT"
  echo "  Triggers:     ${INPUT_TRIGGERS}"
  echo "  Comparing to: $COMPARE_REF"
  echo ""
  echo -e "$DETAILS_LOG"
  echo "::endgroup::"
  if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
    echo "::notice title=Diff Triggers::ℹ️ Diff Triggers not fired. (${GITHUB_REPOSITORY})"
  fi
  echo "triggered=false" >> "$GITHUB_OUTPUT"
fi
