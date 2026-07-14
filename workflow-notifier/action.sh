#!/bin/bash
set -euo pipefail

# Helper functions for consistency across all actions
function log_debug() {
  if [ "${INPUT_DEBUG:-}" == "true" ]; then
    echo "DEBUG: $1"
  fi
}


# 1. Discover CODEOWNERS (root, .github/, docs/)
CODEOWNERS_PATH=""
for path in "CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS" ".github/codeowners"; do
  if [ -f "$path" ]; then
    CODEOWNERS_PATH="$path"
    log_debug "Found CODEOWNERS at $path"
    break
  fi
done

# 2. Extract Owners (Exclude teams)
ASSIGNEES=""
if [ -n "$CODEOWNERS_PATH" ]; then
  ASSIGNEES=$(grep -v '^#' "$CODEOWNERS_PATH" | grep -o '@[a-zA-Z0-9_-]\+' | grep -v '/' | sed 's/@//g' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  log_debug "Owners found: ${ASSIGNEES}"
fi

# 3. Build the Issue Body
FINAL_BODY="${INPUT_BODY:-"Workflow failure detected at $(date)."}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
# Use printf to handle newlines correctly
printf -v FINAL_BODY "%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$RUN_URL"

# 4. Create the Issue via gh CLI
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
if [ "${INPUT_ASSIGN}" == "true" ] && [ -n "$ASSIGNEES" ]; then
  CLEAN_ASSIGNEES=$(echo "$ASSIGNEES" | cut -d',' -f1-10)
  GH_ARGS+=(--assignee "$CLEAN_ASSIGNEES")
fi

# Execute or Dry Run
REDACTED_GH_ARGS=("${GH_ARGS[@]}")
for i in "${!REDACTED_GH_ARGS[@]}"; do
  if [ "${REDACTED_GH_ARGS[i]}" == "--body" ] && [ $((i + 1)) -lt ${#REDACTED_GH_ARGS[@]} ]; then
    REDACTED_GH_ARGS[$((i+1))]="[MASKED]"
  fi
done

log_debug "Constructed gh arguments: gh ${REDACTED_GH_ARGS[*]}"
if [ "${INPUT_DRY_RUN}" == "true" ]; then
  echo "::notice ::[DRY RUN] Would create issue: gh ${REDACTED_GH_ARGS[*]}"
  ISSUE_NUM="0"
  ISSUE_URL="https://github.com/${GITHUB_REPOSITORY}/issues/dry-run"
else
  log_debug "Executing gh CLI to create issue"
  ISSUE_URL=$(GH_TOKEN="${INPUT_TOKEN}" gh "${GH_ARGS[@]}")
  ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || echo "0")
fi

echo "Summary ---"
printf "\tIssue: #%s\n" "${ISSUE_NUM}"
printf "\tURL:   %s\n" "${ISSUE_URL}"

# Write outputs (useful even in dry runs)
echo "issue_number=${ISSUE_NUM}" >> "${GITHUB_OUTPUT}"
echo "assignees=${ASSIGNEES}" >> "${GITHUB_OUTPUT}"

log_debug "Action completed successfully."
