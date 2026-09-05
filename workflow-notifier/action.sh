#!/bin/bash
set -euo pipefail

if [ "${INPUT_DEBUG:-}" == "true" ]; then
  set -x
fi

# Helper functions for consistency across all actions
function log_debug() {
  if [ "${INPUT_DEBUG:-}" == "true" ]; then
    echo "DEBUG: $1"
  fi
}


# 1. Discover CODEOWNERS (root, .github/, docs/)
CODEOWNERS_PATH=""
if [ "${INPUT_NOTIFY_CODEOWNERS:-true}" == "true" ]; then
  for path in "CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS" ".github/codeowners"; do
    if [ -f "$path" ]; then
      CODEOWNERS_PATH="$path"
      log_debug "Found CODEOWNERS at $path"
      break
    fi
  done
else
  log_debug "CODEOWNERS notification disabled (notify_codeowners: false)"
fi

# 2. Extract Owners (Exclude teams)
ASSIGNEES=""
if [ -n "$CODEOWNERS_PATH" ]; then
  ASSIGNEES=$(grep -v '^#' "$CODEOWNERS_PATH" | grep -o '@[a-zA-Z0-9_-]\+' | grep -v '/' | sed 's/@//g' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  log_debug "Owners found: ${ASSIGNEES}"
fi

# 3. Discover Triggering Author / Merger
AUTHORS_LIST=()
TRIGGER_NOTE=""

if [ "${INPUT_NOTIFY_AUTHOR:-true}" == "true" ]; then
  PR_NUM=""
  PR_AUTHOR=""
  MERGER="${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"
  if [[ "$MERGER" == *"[bot]"* ]] || [ "$MERGER" == "null" ]; then
    MERGER=""
  fi
  MERGER="${MERGER#@}"

  # For commits associated with a PR, resolve PR number, author, and merger
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ] && [ -n "${INPUT_TOKEN:-}" ]; then
    log_debug "Attempting to resolve PR metadata for ${GITHUB_SHA}..."
    PR_INFO=$(GH_TOKEN="${INPUT_TOKEN}" gh api "/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" --jq '.[0] | "\(.number // "")|\(.merged_by.login // "")|\(.user.login // "")"' 2>/dev/null || true)
    if [ -n "$PR_INFO" ] && [ "$PR_INFO" != "||" ]; then
      IFS='|' read -r PR_NUM RAW_MERGER PR_AUTHOR <<< "$PR_INFO" || true
      if [ -n "$RAW_MERGER" ] && [[ "$RAW_MERGER" != *"[bot]"* ]]; then
        MERGER="$RAW_MERGER"
      fi
    fi
  fi

  # Filter out bot PR author
  if [[ "$PR_AUTHOR" == *"[bot]"* ]] || [ "$PR_AUTHOR" == "null" ]; then
    PR_AUTHOR=""
  fi
  PR_AUTHOR="${PR_AUTHOR#@}"

  lower_m=$(echo "$MERGER" | tr '[:upper:]' '[:lower:]')
  lower_a=$(echo "$PR_AUTHOR" | tr '[:upper:]' '[:lower:]')

  if [ -n "$MERGER" ]; then
    AUTHORS_LIST+=("$MERGER")
  fi
  if [ -n "$PR_AUTHOR" ] && [ "$lower_a" != "$lower_m" ]; then
    AUTHORS_LIST+=("$PR_AUTHOR")
  fi

  # Build trigger note for issue body
  if [ -n "$MERGER" ] && [ -n "$PR_AUTHOR" ] && [ "$lower_a" != "$lower_m" ]; then
    if [ -n "$PR_NUM" ]; then
      TRIGGER_NOTE="Triggered by @${MERGER} (PR #${PR_NUM} by @${PR_AUTHOR})"
    else
      TRIGGER_NOTE="Triggered by @${MERGER} (authored by @${PR_AUTHOR})"
    fi
  elif [ -n "$MERGER" ]; then
    TRIGGER_NOTE="Triggered by @${MERGER}"
  elif [ -n "$PR_AUTHOR" ]; then
    TRIGGER_NOTE="Triggered by @${PR_AUTHOR}"
  fi

  # Prepend authors to ASSIGNEES (deduplicating case-insensitively)
  for author in "${AUTHORS_LIST[@]}"; do
    log_debug "Adding author to assignees: ${author}"
    if [ -n "$ASSIGNEES" ]; then
      REMAINING_ASSIGNEES=$(echo "$ASSIGNEES" | tr ',' '\n' | grep -i -F -v -x "$author" | tr '\n' ',' | sed 's/,$//' || true)
      if [ -n "$REMAINING_ASSIGNEES" ]; then
        ASSIGNEES="${author},${REMAINING_ASSIGNEES}"
      else
        ASSIGNEES="${author}"
      fi
    else
      ASSIGNEES="${author}"
    fi
  done
fi

# 4. Build the Issue Body
FINAL_BODY="${INPUT_BODY:-"Workflow failure detected at $(date)."}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local/repo}/actions/runs/${GITHUB_RUN_ID:-0}"

if [ -n "$TRIGGER_NOTE" ]; then
  printf -v FINAL_BODY "%s\n\n%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$TRIGGER_NOTE" "$RUN_URL"
else
  printf -v FINAL_BODY "%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$RUN_URL"
fi
log_debug "Issue body: ${FINAL_BODY}"

# 5. Create the Issue via gh CLI
log_debug "Creating issue: $INPUT_TITLE"

# Construct the command array
GH_ARGS=(issue create --title "$INPUT_TITLE" --body "$FINAL_BODY")

# Split labels on comma and add --label for each
if [ -n "${INPUT_LABELS:-}" ]; then
  # read -a returns 1 on empty input, so we use || true inside the condition or just trust the if -n
  IFS=',' read -r -a LABELS_ARRAY <<< "$INPUT_LABELS" || true
  for label in "${LABELS_ARRAY[@]}"; do
    # Trim whitespace
    label=$(echo "$label" | xargs)
    if [ -n "$label" ]; then
      GH_ARGS+=(--label "$label")
    fi
  done
fi

# Handle assignment (limit 10 for GitHub)
if [ "${INPUT_ASSIGN:-}" == "true" ] && [ -n "$ASSIGNEES" ]; then
  CLEAN_ASSIGNEES=$(echo "$ASSIGNEES" | cut -d',' -f1-10)
  GH_ARGS+=(--assignee "$CLEAN_ASSIGNEES")
fi

# Execute or Dry Run
REDACTED_GH_ARGS=("${GH_ARGS[@]}")
for i in "${!REDACTED_GH_ARGS[@]}"; do
  if [ "${REDACTED_GH_ARGS[i]}" == "--body" ] && [ $((i + 1)) -lt ${#REDACTED_GH_ARGS[@]} ]; then
    REDACTED_GH_ARGS[i+1]="[MASKED]"
  fi
done

log_debug "Constructed gh arguments: gh ${REDACTED_GH_ARGS[*]}"
if [ "${INPUT_DRY_RUN:-}" == "true" ]; then
  echo "::notice ::[DRY RUN] Would create issue: gh ${REDACTED_GH_ARGS[*]}"
  ISSUE_NUM="0"
  ISSUE_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local/repo}/issues/dry-run"
else
  log_debug "Executing gh CLI to create issue"
  ISSUE_URL=$(GH_TOKEN="${INPUT_TOKEN:?Missing required token (INPUT_TOKEN)}" gh "${GH_ARGS[@]}")
  ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || echo "0")
fi

echo "Summary ---"
printf "\tIssue:     #%s\n" "${ISSUE_NUM}"
printf "\tURL:       %s\n" "${ISSUE_URL}"
for author in "${AUTHORS_LIST[@]}"; do
  printf "\tAuthor:    @%s\n" "${author}"
done
printf "\tAssignees: %s\n" "${ASSIGNEES}"

# Write outputs (useful even in dry runs)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "issue_number=${ISSUE_NUM}" >> "${GITHUB_OUTPUT}"
  echo "assignees=${ASSIGNEES}" >> "${GITHUB_OUTPUT}"
fi

log_debug "Action completed successfully."
