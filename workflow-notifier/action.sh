#!/bin/bash
set -euo pipefail

# Shared input rules (see shared/README.md); each call fails the step with an annotation on bad input
SHARED_INPUTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../shared/inputs.js"
INPUT_DEBUG="$(node "$SHARED_INPUTS" debug)"
INPUT_NOTIFY_AUTHOR="$(node "$SHARED_INPUTS" bool notify_author true)"
INPUT_DRY_RUN="$(node "$SHARED_INPUTS" bool dry_run false)"
NOTIFY_CODEOWNERS_MODE="$(node "$SHARED_INPUTS" enum notify_codeowners always,fallback,never fallback)"
CODEOWNERS_MATCH="$(node "$SHARED_INPUTS" enum codeowners_match all,changed,workflow all)"
CODEOWNERS_JS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codeowners.js"
INPUT_TOKEN="$(node "$SHARED_INPUTS" token)"
INPUT_TITLE="${INPUT_TITLE:-"fix: failure in ${GITHUB_WORKFLOW:-workflow}"}"

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
PR_NUM=""
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

# 2. Discover CODEOWNERS (GitHub order: .github/, root, docs/)
CODEOWNERS_PATH=""
while IFS= read -r path; do
  if [ -f "$path" ]; then
    CODEOWNERS_PATH="$path"
    log_debug "Found CODEOWNERS at $path"
    break
  fi
done < <(node "$CODEOWNERS_JS" search-order)

# Failing workflow file, e.g. .github/workflows/merge.yml (from owner/repo/<path>@ref)
workflow_file() {
  local ref="${GITHUB_WORKFLOW_REF:-}"
  ref="${ref%%@*}"
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    ref="${ref#"${GITHUB_REPOSITORY}/"}"
  fi
  printf '%s' "$ref"
}

# Changed files of the PR behind this run: the event's PR, else the merged PR for GITHUB_SHA
pr_changed_files() {
  local num="$PR_NUM"
  if [ -z "$num" ] && [[ "$EVENT_NAME" == pull_request* ]] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    num="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
  fi
  if [ -z "$num" ] && [ "$EVENT_NAME" == "push" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ] && [ -n "${INPUT_TOKEN:-}" ]; then
    local info attempt
    for attempt in 1 2 3; do
      info=$(GH_TOKEN="${INPUT_TOKEN}" gh api "/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" --jq '[.[] | select(.merged_at != null)][0] | "\(.number // "")|\(.merged_by.login // "")|\(.user.login // "")"' 2>/dev/null || true)
      num="${info%%|*}"
      [ -n "$num" ] && break
      if [ "$attempt" -lt 3 ]; then
        sleep $((attempt * 2))
      fi
    done
  fi
  [ -z "$num" ] && return 0
  [ -z "${INPUT_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ] && return 0
  CHANGED_PR="$num"
  local files
  if ! files="$(GH_TOKEN="${INPUT_TOKEN}" gh api --paginate "/repos/${GITHUB_REPOSITORY}/pulls/${num}/files" --jq '.[].filename' 2>"${CHANGED_ERR_FILE}")"; then
    # Partial pages are discarded so owners never come from an incomplete list
    return 2
  fi
  printf '%s\n' "$files"
}

CODEOWNERS_HANDLES=""
CODEOWNERS_TEAMS=""
CODEOWNERS_EMAILS="0"
CODEOWNERS_REASON="mode=${CODEOWNERS_MATCH}"
CHANGED_PR=""
if [ -n "$CODEOWNERS_PATH" ]; then
  MATCH_PATHS=""
  SELECT_MODE="all"
  if [ "$CODEOWNERS_MATCH" == "changed" ]; then
    SELECT_MODE="paths"
    CHANGED_FILES_FILE="$(mktemp)"
    CHANGED_ERR_FILE="$(mktemp)"
    FILES_STATUS=0
    pr_changed_files > "$CHANGED_FILES_FILE" || FILES_STATUS=$?
    MATCH_PATHS="$(sed '/^$/d' "$CHANGED_FILES_FILE")"
    if [ "$FILES_STATUS" -ne 0 ]; then
      echo "::warning ::workflow-notifier: could not list files for PR #${CHANGED_PR}: $(tr '\n' ' ' < "$CHANGED_ERR_FILE")"
      MATCH_PATHS="$(workflow_file)"
      CODEOWNERS_REASON="mode=changed, PR #${CHANGED_PR} files lookup failed; fell back to workflow (${MATCH_PATHS:-unknown})"
    elif [ -n "$MATCH_PATHS" ]; then
      CODEOWNERS_REASON="mode=changed (PR #${CHANGED_PR}, $(printf '%s\n' "$MATCH_PATHS" | wc -l | tr -d ' ') file(s))"
    else
      MATCH_PATHS="$(workflow_file)"
      CODEOWNERS_REASON="mode=changed, no PR files found; fell back to workflow (${MATCH_PATHS:-unknown})"
    fi
    rm -f "$CHANGED_FILES_FILE" "$CHANGED_ERR_FILE"
  elif [ "$CODEOWNERS_MATCH" == "workflow" ]; then
    SELECT_MODE="paths"
    MATCH_PATHS="$(workflow_file)"
    CODEOWNERS_REASON="mode=workflow (${MATCH_PATHS:-unknown})"
  fi
  SELECTED="$(printf '%s\n' "$MATCH_PATHS" | node "$CODEOWNERS_JS" "$CODEOWNERS_PATH" "$SELECT_MODE")"
  CODEOWNERS_HANDLES="$(sed -n 's/^users=//p' <<< "$SELECTED")"
  CODEOWNERS_TEAMS="$(sed -n 's/^teams=//p' <<< "$SELECTED")"
  CODEOWNERS_EMAILS="$(sed -n 's/^emails=//p' <<< "$SELECTED")"
  log_debug "CODEOWNERS handles: ${CODEOWNERS_HANDLES}"
fi

# No CODEOWNERS in the workspace: names from .github/CODEOWNERS at this commit, or nothing
codeowners_names() {
  GH_TOKEN="${INPUT_TOKEN}" gh api -H "Accept: application/vnd.github.raw" \
    "/repos/${GITHUB_REPOSITORY:-}/contents/.github/CODEOWNERS${GITHUB_SHA:+?ref=${GITHUB_SHA}}" 2>/dev/null \
    | node "$CODEOWNERS_JS" /dev/stdin all | sed -n 's/^users=//p'
}
if [ -z "$CODEOWNERS_PATH" ] && [ "$NOTIFY_CODEOWNERS_MODE" != "never" ]; then
  CODEOWNERS_HANDLES="$(codeowners_names || true)"
  if [ -z "$CODEOWNERS_HANDLES" ]; then
    echo "::error::No names returned from codeowners"
    exit 1
  fi
  CODEOWNERS_PATH=".github/CODEOWNERS"
fi

# Determine whether CODEOWNERS should be included
INCLUDE_CODEOWNERS=false

if [ "$NOTIFY_CODEOWNERS_MODE" == "always" ]; then
  INCLUDE_CODEOWNERS=true
elif [ "$NOTIFY_CODEOWNERS_MODE" == "never" ]; then
  INCLUDE_CODEOWNERS=false
else
  # "fallback": include CODEOWNERS only if no human authors were identified
  if [ ${#AUTHORS_LIST[@]} -eq 0 ]; then
    INCLUDE_CODEOWNERS=true
  fi
fi

# Log and summarize which CODEOWNERS file, handles and why
if [ -n "$CODEOWNERS_PATH" ]; then
  CO_LINES=("CODEOWNERS: ${CODEOWNERS_PATH}, ${CODEOWNERS_REASON}")
  if [ "$INCLUDE_CODEOWNERS" != "true" ]; then
    CO_LINES+=("CODEOWNERS users not included (notify_codeowners=${NOTIFY_CODEOWNERS_MODE})")
  elif [ -n "$CODEOWNERS_HANDLES" ]; then
    CO_LINES+=("CODEOWNERS users selected: @${CODEOWNERS_HANDLES//,/ @}")
  else
    CO_LINES+=("CODEOWNERS users selected: none")
  fi
  if [ -n "$CODEOWNERS_TEAMS" ]; then
    CO_LINES+=("CODEOWNERS teams skipped (teams cannot be assigned): @${CODEOWNERS_TEAMS//,/ @}")
  fi
  if [ "${CODEOWNERS_EMAILS:-0}" != "0" ]; then
    CO_LINES+=("CODEOWNERS email owners ignored: ${CODEOWNERS_EMAILS}")
  fi
else
  CO_LINES=("CODEOWNERS: none found")
fi
for line in "${CO_LINES[@]}"; do
  echo "$line"
done
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### workflow-notifier"
    for line in "${CO_LINES[@]}"; do
      echo "- ${line}"
    done
  } >> "$GITHUB_STEP_SUMMARY"
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
RUN_LINE="- $(date -u +"%Y-%m-%dT%H:%M:%SZ") — [run](${RUN_URL})"

if [ -n "$TRIGGER_NOTE" ]; then
  printf -v FINAL_BODY "%s\n\n%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$TRIGGER_NOTE" "$RUN_URL"
else
  printf -v FINAL_BODY "%s\n\n[View Workflow Run](%s)" "$FINAL_BODY" "$RUN_URL"
fi
log_debug "Issue body: ${FINAL_BODY}"

copy_redacted_gh_args() {
  local i
  REDACTED_GH_ARGS=("${GH_ARGS[@]}")
  for i in "${!REDACTED_GH_ARGS[@]}"; do
    if [ "${REDACTED_GH_ARGS[$i]}" = "--body" ] && [ $((i + 1)) -lt ${#REDACTED_GH_ARGS[@]} ]; then
      REDACTED_GH_ARGS[$((i + 1))]="[MASKED]"
    fi
  done
}

# Handle assignment (limit 10 for GitHub). Applied on create only.
CLEAN_ASSIGNEES=""
if [ -n "$ASSIGNEES" ]; then
  CLEAN_ASSIGNEES=$(echo "$ASSIGNEES" | cut -d',' -f1-10)
fi

# 5. Reuse one open issue with this exact title, or create one.
# ponytail: title match scans at most 100 open issues (gh list order, first exact hit).
# Two overlapping runs can both miss and both create. No lock.
MATCHED_NUM=""
ISSUE_ACTION="created"
if [ -n "${INPUT_TOKEN:-}" ]; then
  REPO="${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}"
  LIST_OUT="$(GH_TOKEN="${INPUT_TOKEN}" gh issue list \
    --repo "$REPO" \
    --state open \
    --limit 100 \
    --json number,title \
    --jq '.[] | [.number, .title] | @tsv')"
  while IFS=$'\t' read -r num title; do
    [ -z "$num" ] && continue
    [ "$title" = "$INPUT_TITLE" ] || continue
    MATCHED_NUM="$num"
    break
  done <<< "$LIST_OUT"
elif [ "${INPUT_DRY_RUN:-}" != "true" ]; then
  echo "Missing required token (INPUT_TOKEN)" >&2
  exit 1
fi

if [ -n "$MATCHED_NUM" ]; then
  ISSUE_ACTION="commented"
  ISSUE_NUM="$MATCHED_NUM"
  ISSUE_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/issues/${MATCHED_NUM}"
  GH_ARGS=(issue comment "$MATCHED_NUM" --repo "$REPO" --body "$RUN_LINE")
  copy_redacted_gh_args
  log_debug "Constructed gh arguments: gh ${REDACTED_GH_ARGS[*]}"
  if [ "${INPUT_DRY_RUN:-}" = "true" ]; then
    echo "::notice ::[DRY RUN] Would comment on issue: gh ${REDACTED_GH_ARGS[*]}"
    ISSUE_NUM="0"
    ISSUE_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/issues/dry-run"
  else
    log_debug "Executing gh CLI to comment on issue #${MATCHED_NUM}"
    GH_TOKEN="${INPUT_TOKEN}" gh "${GH_ARGS[@]}"
  fi
else
  log_debug "Creating issue: $INPUT_TITLE"

  GH_ARGS=(issue create --title "$INPUT_TITLE" --body "$FINAL_BODY")
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    GH_ARGS+=(--repo "$GITHUB_REPOSITORY")
  fi

  if [ -n "$CLEAN_ASSIGNEES" ]; then
    GH_ARGS+=(--assignee "$CLEAN_ASSIGNEES")
  fi

  copy_redacted_gh_args
  log_debug "Constructed gh arguments: gh ${REDACTED_GH_ARGS[*]}"
  if [ "${INPUT_DRY_RUN:-}" = "true" ]; then
    echo "::notice ::[DRY RUN] Would create issue: gh ${REDACTED_GH_ARGS[*]}"
    ISSUE_NUM="0"
    ISSUE_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local/repo}/issues/dry-run"
  else
    log_debug "Executing gh CLI to create issue"
    ISSUE_URL="$(GH_TOKEN="${INPUT_TOKEN:?Missing required token (INPUT_TOKEN)}" gh "${GH_ARGS[@]}")"
    ISSUE_NUM="$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || echo "0")"
  fi
fi

echo "Summary ---"
printf "\tAction:    %s\n" "${ISSUE_ACTION}"
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

log_debug "Action completed successfully."
