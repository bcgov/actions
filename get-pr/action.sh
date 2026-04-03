#!/bin/bash
set -euo pipefail

# Helper functions for consistency across all actions
function log_debug() {
  if [ "${INPUT_DEBUG:-}" == "true" ]; then
    echo "DEBUG: $1"
  fi
}

function get_pr_from_api() {
  local url=$1
  log_debug "Querying GitHub API: $url"
  curl -sL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url" 2>/dev/null
}

function get_pr_from_api_response() {
  local response=$1
  echo "$response" | jq -r '.[0].number // empty' 2>/dev/null
}

function get_pr_from_git() {
  local commits=${1:-1}
  log_debug "Searching git history (last $commits commits)..."
  git log --pretty=format:%s -"${commits}" 2>/dev/null | while read -r line; do
    trimmed="${line%"${line##*[![:space:]]}"}"
    if [[ $trimmed =~ \(#([0-9]+)\)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      break
    fi
  done
}

# 1. Process variables and inputs
pr=""
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
log_debug "Event Name: $EVENT_NAME"

case "${EVENT_NAME}" in
  "")
    echo "Event type: local run (no GitHub event)"
    pr=$(get_pr_from_git)
    ;;
  "pull_request")
    echo "Event type: pull request"
    pr="${GITHUB_EVENT_NUMBER:-}"
    ;;
  "merge_group")
    echo "Event type: merge queue"
    if [ -n "${MERGE_GROUP_HEAD_REF:-}" ]; then
      # MERGE_GROUP_HEAD_REF format: queue/<branch>/pr-<number>
      pr=$(echo "${MERGE_GROUP_HEAD_REF}" | sed -n 's|^queue/[^/]*/pr-\([0-9]\+\).*|\1|p')
    fi
    ;;
  "push")
    echo "Event type: push"
    if [ -n "${GITHUB_EVENT_AFTER:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_EVENT_AFTER}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
    fi
    ;;
  "release")
    echo "Event type: release"
    if [ -n "${GITHUB_SHA:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
    fi
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      log_debug "API method failed, trying git history"
      pr=$(get_pr_from_git)
    fi
    ;;
  "workflow_dispatch")
    echo "Event type: workflow_dispatch"
    pr=$(get_pr_from_git)
    if [ -z "${pr}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ]; then
      log_debug "Commit message method failed, trying API"
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
    fi
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      log_debug "API method failed, searching recent commit history"
      pr=$(get_pr_from_git 10)
    fi
    ;;
  *)
    echo "Event type: $EVENT_NAME (unknown or unexpected)"
    # We don't exit 1 here to avoid breaking workflows that might run on mixed events
    ;;
esac

# 2. Validation & Output
log_debug "Final Found PR: ${pr:-none}"

if [ -n "$pr" ] && [[ "${pr}" =~ ^[0-9]+$ ]]; then
  echo "Associated PR found: ${pr}"
  echo "pr=${pr}" >> "$GITHUB_OUTPUT"
else
  echo "No PR number found."
  echo "pr=" >> "$GITHUB_OUTPUT"
fi
