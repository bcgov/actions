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


# 1. Discover Triggering Actor / Merger / Author based on Event
AUTHORS_LIST=()
TRIGGER_NOTE=""
EVENT_NAME="${INPUT_EVENT_NAME:-${GITHUB_EVENT_NAME:-push}}"

if [ "${INPUT_NOTIFY_AUTHOR:-true}" == "true" ]; then
  if [ "$EVENT_NAME" == "workflow_dispatch" ]; then
    OPERATOR="${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"
    if [[ "$OPERATOR" == *"[bot]"* ]] || [ "$OPERATOR" == "null" ]; then
      OPERATOR=""
    fi
    OPERATOR="${OPERATOR#@}"
    if [ -n "$OPERATOR" ]; then
      AUTHORS_LIST+=("$OPERATOR")
      TRIGGER_NOTE="Dispatched by @${OPERATOR}"
    fi
  elif [ "$EVENT_NAME" == "schedule" ]; then
    TRIGGER_NOTE="Triggered by scheduled automation"
  elif [ "$EVENT_NAME" == "push" ]; then
    # push event: resolve PR metadata if commit SHA and repo are available (with bounded retry for indexing lag)
    PR_NUM=""
    PR_AUTHOR=""
    MERGER="${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"
    if [[ "$MERGER" == *"[bot]"* ]] || [ "$MERGER" == "null" ]; then
      MERGER=""
    fi
    MERGER="${MERGER#@}"

    if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ] && [ -n "${INPUT_TOKEN:-}" ]; then
      log_debug "Attempting to resolve PR metadata for ${GITHUB_SHA}..."
      PR_INFO=""
      for attempt in 1 2 3; do
        PR_INFO=$(GH_TOKEN="${INPUT_TOKEN}" gh api "/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" --jq '[.[] | select(.merged_at != null)][0] | "\(.number // "")|\(.merged_by.login // "")|\(.user.login // "")"' 2>/dev/null || true)
        if [ -n "$PR_INFO" ] && [ "$PR_INFO" != "||" ]; then
          break
        fi
        if [ "$attempt" -lt 3 ]; then
          sleep $((attempt * 2))
        fi
      done
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
      printf -v TRIGGER_NOTE "Merged by @%s\nAuthored by @%s" "$MERGER" "$PR_AUTHOR"
    elif [ -n "$MERGER" ] && [ -n "$PR_AUTHOR" ] && [ "$lower_a" == "$lower_m" ]; then
      TRIGGER_NOTE="Merged and authored by @${MERGER}"
    elif [ -n "$MERGER" ]; then
      if [ -n "$PR_NUM" ]; then
        TRIGGER_NOTE="Merged by @${MERGER}"
      else
        TRIGGER_NOTE="Pushed by @${MERGER}"
      fi
    elif [ -n "$PR_AUTHOR" ]; then
      TRIGGER_NOTE="Authored by @${PR_AUTHOR}"
    fi
  else
    # pull_request or other generic events: attribute to triggering actor with neutral wording
    ACTOR="${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"
    if [[ "$ACTOR" == *"[bot]"* ]] || [ "$ACTOR" == "null" ]; then
      ACTOR=""
    fi
    ACTOR="${ACTOR#@}"
    if [ -n "$ACTOR" ]; then
      AUTHORS_LIST+=("$ACTOR")
      TRIGGER_NOTE="Triggered by @${ACTOR}"
    fi
  fi
fi

# 2. Discover CODEOWNERS (root, .github/, docs/)
CODEOWNERS_PATH=""
for path in "CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS" ".github/codeowners"; do
  if [ -f "$path" ]; then
    CODEOWNERS_PATH="$path"
    log_debug "Found CODEOWNERS at $path"
    break
  fi
done

CODEOWNERS_HANDLES=""
if [ -n "$CODEOWNERS_PATH" ]; then
  CODEOWNERS_HANDLES=$(grep -v '^#' "$CODEOWNERS_PATH" | grep -o '@[a-zA-Z0-9_-]\+' | grep -v '/' | sed 's/@//g' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  log_debug "CODEOWNERS handles: ${CODEOWNERS_HANDLES}"
fi

# Determine whether CODEOWNERS should be included
NOTIFY_CODEOWNERS_MODE=$(echo "${INPUT_NOTIFY_CODEOWNERS:-fallback}" | tr '[:upper:]' '[:lower:]')
INCLUDE_CODEOWNERS=false

if [ "$NOTIFY_CODEOWNERS_MODE" == "true" ]; then
  INCLUDE_CODEOWNERS=true
elif [ "$NOTIFY_CODEOWNERS_MODE" == "false" ]; then
  INCLUDE_CODEOWNERS=false
else
  # "fallback": include CODEOWNERS only if no human authors were identified
  if [ ${#AUTHORS_LIST[@]} -eq 0 ]; then
    INCLUDE_CODEOWNERS=true
  fi
fi

# 3. Assemble ASSIGNEES (Case-insensitively deduplicated)
ASSIGNEES=""
for author in "${AUTHORS_LIST[@]}"; do
  log_debug "Adding author to assignees: ${author}"
  if [ -z "$ASSIGNEES" ]; then
    ASSIGNEES="$author"
  else
    if ! echo "$ASSIGNEES" | tr ',' '\n' | grep -i -q -x "$author"; then
      ASSIGNEES="${ASSIGNEES},${author}"
    fi
  fi
done

if [ "$INCLUDE_CODEOWNERS" == "true" ] && [ -n "$CODEOWNERS_HANDLES" ]; then
  log_debug "Adding CODEOWNERS to assignees..."
  IFS=',' read -r -a OWNERS_ARRAY <<< "$CODEOWNERS_HANDLES" || true
  for owner in "${OWNERS_ARRAY[@]}"; do
    owner=$(echo "$owner" | xargs)
    [ -z "$owner" ] && continue
    if [ -z "$ASSIGNEES" ]; then
      ASSIGNEES="$owner"
    else
      if ! echo "$ASSIGNEES" | tr ',' '\n' | grep -i -q -x "$owner"; then
        ASSIGNEES="${ASSIGNEES},${owner}"
      fi
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
CLEAN_ASSIGNEES=""
if [ -n "$ASSIGNEES" ]; then
  CLEAN_ASSIGNEES=$(echo "$ASSIGNEES" | cut -d',' -f1-10)
fi

if [ "${INPUT_ASSIGN:-}" == "true" ] && [ -n "$CLEAN_ASSIGNEES" ]; then
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
if [ -n "$TRIGGER_NOTE" ]; then
  while IFS= read -r line; do
    printf "\tNote:      %s\n" "${line}"
  done <<< "$TRIGGER_NOTE"
fi
printf "\tAssignees: %s\n" "${CLEAN_ASSIGNEES}"

# Write outputs (useful even in dry runs)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "issue_number=${ISSUE_NUM}" >> "${GITHUB_OUTPUT}"
  echo "assignees=${CLEAN_ASSIGNEES}" >> "${GITHUB_OUTPUT}"
fi

log_debug "Action completed successfully."
