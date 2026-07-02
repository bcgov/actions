#!/usr/bin/env bash
# Forensic extraction of core logic from bcgov/action-diff-triggers baseline.
# Consolidated to monorepo to maintain same-commit orchestration.

set -e

CALLER_CONTEXT="[${GITHUB_WORKFLOW:-} / ${GITHUB_JOB:-}]"
ANNOTATIONS_ENABLED="${INPUT_ANNOTATIONS:-true}"
ANNOTATIONS_ENABLED="$(echo "$ANNOTATIONS_ENABLED" | tr '[:upper:]' '[:lower:]')"

# Always fire if triggers are omitted
if [ -z "${INPUT_TRIGGERS:-}" ]; then
  echo "::group::Diff Triggers — ✅ TRIGGERED | ${GITHUB_REPOSITORY:-} $CALLER_CONTEXT"
  echo "  Triggers: (omitted, always fires)"
  echo "::endgroup::"
  if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
    echo "::notice title=Diff Triggers [${GITHUB_JOB:-}]::✅ Omitted (always fires)."
  fi
  echo "triggered=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Build if changed files (git diff) match triggers
# Parse triggers input into array (properly handles quoted strings with spaces)
TRIGGERS_STR="${INPUT_TRIGGERS}"
# Escape %, \n, \r for GitHub Actions workflow command encoding
ESCAPED_TRIGGERS="${TRIGGERS_STR//%/%25}"
ESCAPED_TRIGGERS="${ESCAPED_TRIGGERS//$'\n'/%0A}"
ESCAPED_TRIGGERS="${ESCAPED_TRIGGERS//$'\r'/%0D}"
# Extract all quoted strings preserving spaces within quotes
TRIGGERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TRIGGERS+=("$line")
done < <(grep -o "'[^']*'" <<< "$TRIGGERS_STR" | sed "s/'//g")

# Fallback for unquoted formats: "./path1/ ./path2/" or "./path1/,./path2/"
if [[ ${#TRIGGERS[@]} -eq 0 ]]; then
  NORMALIZED="${TRIGGERS_STR//,/ }"
  for trigger in ${NORMALIZED}; do
    [[ -n "$trigger" ]] && TRIGGERS+=("$trigger")
  done
fi

# Ensure parsing resolved at least one trigger path to check
if [[ ${#TRIGGERS[@]} -eq 0 ]]; then
  echo "::error::Could not parse any triggers from input: $TRIGGERS_STR"
  exit 1
fi

# Determine reference to compare against
# PR events: default to base repo default branch if ref omitted
# Non-PR events: default to HEAD^ if ref omitted
BASE_REF="${INPUT_REF:-}"
if [ -z "$BASE_REF" ]; then
  BASE_REF="${EVENT_PR_BASE_DEFAULT_BRANCH:-}"
fi
if [ -z "$BASE_REF" ]; then
  BASE_REF="HEAD^"
fi

if [ -n "${INPUT_REF:-}" ]; then
  REF_SOURCE="input"
else
  REF_SOURCE="default"
fi

BASE_REMOTE_URL="${EVENT_PR_BASE_CLONE_URL:-$EVENT_REPOSITORY_CLONE_URL}"
# Ensure remote URL is authenticated (required for private repos)
if [[ -n "${INPUT_GITHUB_TOKEN:-}" && "$BASE_REMOTE_URL" == https://github.com/* ]]; then
  BASE_REMOTE_URL="https://x-access-token:${INPUT_GITHUB_TOKEN}@github.com/${BASE_REMOTE_URL#https://github.com/}"
fi
if git remote get-url base >/dev/null 2>&1; then
  git remote set-url base "$BASE_REMOTE_URL"
else
  git remote add base "$BASE_REMOTE_URL" 2>/dev/null || git remote set-url base "$BASE_REMOTE_URL"
fi

# If BASE_REF starts with HEAD, it's a local ref - use it directly
# Otherwise, fetch from remote and prefix
if [[ "$BASE_REF" == HEAD* ]]; then
  COMPARE_REF="$BASE_REF"
else
  git fetch base "$BASE_REF"
  COMPARE_REF="base/$BASE_REF"
fi

# Check all triggers and collect results
TRIGGERED=false
MATCHED_TRIGGERS=()
DETAILS_LOG=""

for t in "${TRIGGERS[@]}"; do
  DIFF_OUTPUT=$(git diff "$COMPARE_REF" HEAD --name-only -- "$t")
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

# Single collapsible group — result in the title, details inside
if [[ "$TRIGGERED" == "true" ]]; then
  MATCHED_LIST=$(IFS=', '; echo "${MATCHED_TRIGGERS[*]}")
  echo "::group::Diff Triggers — ✅ TRIGGERED | ${GITHUB_REPOSITORY:-} $CALLER_CONTEXT"
  echo "  Triggers:     $TRIGGERS_STR"
  echo "  Comparing to: $COMPARE_REF"
  echo "  Ref source:   $REF_SOURCE"
  echo "  Matched:      $MATCHED_LIST"
  echo ""
  echo "$DETAILS_LOG"
  echo "::endgroup::"
  if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
    echo "::notice title=Diff Triggers [${GITHUB_JOB:-}]::✅ Fired. Triggers: $ESCAPED_TRIGGERS"
  fi
  echo "triggered=true" >> "$GITHUB_OUTPUT"
else
  echo "::group::Diff Triggers — ⊘ NOT TRIGGERED | ${GITHUB_REPOSITORY:-} $CALLER_CONTEXT"
  echo "  Triggers:     $TRIGGERS_STR"
  echo "  Comparing to: $COMPARE_REF"
  echo "  Ref source:   $REF_SOURCE"
  echo ""
  echo "$DETAILS_LOG"
  echo "::endgroup::"
  if [[ "$ANNOTATIONS_ENABLED" == "true" ]]; then
    echo "::notice title=Diff Triggers [${GITHUB_JOB:-}]::⊘ Not fired. Triggers: $ESCAPED_TRIGGERS"
  fi
  echo "triggered=false" >> "$GITHUB_OUTPUT"
fi
