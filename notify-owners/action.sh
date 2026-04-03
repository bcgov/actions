#!/bin/bash
set -euo pipefail

# Helper functions for consistency across all actions
function log_debug() {
  [ "${INPUT_DEBUG}" == "true" ] && echo "DEBUG: $1"
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
  ASSIGNEES=$(grep -v '^#' "$CODEOWNERS_PATH" | grep -o '@[a-zA-Z0-9_-]\+' | grep -v '/' | sed 's/@//g' | sort -u | tr '\n' ',' | sed 's/,$//')
  log_debug "Owners found: ${ASSIGNEES}"
fi

# 3. Create Issue
FINAL_BODY="${INPUT_BODY:-"Workflow failure detected at $(date)."}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
FINAL_BODY="${FINAL_BODY}\n\n[View Workflow Run](${RUN_URL})"

# 4. Create the Issue via gh CLI
log_debug "Creating issue: $INPUT_TITLE"

# Construct the command array
GH_ARGS=(issue create --title "$INPUT_TITLE" --body "$FINAL_BODY" --label "$INPUT_LABELS")

# Handle assignment (limit 10 for GitHub)
if [ "${INPUT_ASSIGN}" == "true" ] && [ -n "$ASSIGNEES" ]; then
  CLEAN_ASSIGNEES=$(echo "$ASSIGNEES" | cut -d',' -f1-10)
  GH_ARGS+=(--assignee "$CLEAN_ASSIGNEES")
fi

# Execute or Dry Run
if [ "${INPUT_DRY_RUN}" == "true" ]; then
  echo "::notice ::[DRY RUN] Would create issue: gh ${GH_ARGS[*]}"
  ISSUE_NUM="0"
  ISSUE_URL="https://github.com/${GITHUB_REPOSITORY}/issues/dry-run"
else
  ISSUE_URL=$(GH_TOKEN="${INPUT_TOKEN}" gh "${GH_ARGS[@]}")
  ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
fi

echo "Summary ---"
echo -e "\tIssue: #${ISSUE_NUM}"
echo -e "\tURL:   ${ISSUE_URL}"

[ -n "$INPUT_TOKEN" ] && echo "issue_number=${ISSUE_NUM}" >> $GITHUB_OUTPUT
[ -n "$INPUT_TOKEN" ] && echo "assignees=${ASSIGNEES}" >> $GITHUB_OUTPUT
