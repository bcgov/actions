#!/usr/bin/env bash
set -euo pipefail

# pr-description-add
# Append markdown to the description of the current pull request

if [[ "$GITHUB_EVENT_NAME" != "pull_request" ]]; then
  echo "::error::This action only works on pull_request events."
  exit 1
fi

PR_NUMBER=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")

if [[ -z "$PR_NUMBER" ]]; then
  echo "::error::Could not determine pull request number from event path."
  exit 1
fi

echo "Adding markdown to PR #$PR_NUMBER description..."

# Get current body and append
CURRENT_BODY=$(gh pr view "$PR_NUMBER" --json body --template '{{.body}}')
  # RESTORED IDEMPOTENCY: Check if markdown already exists
  if [[ "$CURRENT_BODY" == *"$MARKDOWN"* ]]; then
    echo "::info::Markdown already present in PR description, skipping."
    exit 0
  fi

NEW_BODY="${CURRENT_BODY}${MARKDOWN}"

gh pr edit "$PR_NUMBER" --body "$NEW_BODY"

echo "pr_number=$PR_NUMBER" >> "$GITHUB_OUTPUT"
