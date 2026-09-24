#!/usr/bin/env bash
# Unit tests for workflow-notifier author discovery, deduplication, and dry-run notifications.

set -euo pipefail

passed=0
failed=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_SH="${SCRIPT_DIR}/../action.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Create a mock gh wrapper for testing API fallbacks
MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "$MOCK_BIN"

cat << 'EOF' > "${MOCK_BIN}/sleep"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/sleep"

cat << 'EOF' > "${MOCK_BIN}/date"
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
  printf '%s\n' "2026-09-22T20:39:12Z"
  exit 0
fi
if [ "$#" -eq 0 ]; then
  printf '%s\n' "Wed Sep 23 04:00:00 UTC 2026"
  exit 0
fi
echo "mock-date: unexpected args: $*" >&2
exit 1
EOF
chmod +x "${MOCK_BIN}/date"

cat << 'EOF' > "${MOCK_BIN}/gh"
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"commits/"*"/pulls"* ]]; then
  json="[]"
  if [ -n "${MOCK_PR_USER:-}" ] || [ -n "${MOCK_PR_MERGER:-}" ]; then
    merger_val="null"
    if [ -n "${MOCK_PR_MERGER:-}" ]; then
      merger_val="\"${MOCK_PR_MERGER}\""
    fi
    user_val="null"
    if [ -n "${MOCK_PR_USER:-}" ]; then
      user_val="\"${MOCK_PR_USER}\""
    fi
    pr_num="${MOCK_PR_NUM:-123}"
    merged_at_val="\"2026-09-05T12:00:00Z\""
    if [ "${MOCK_PR_MERGED:-true}" = "false" ]; then
      merged_at_val="null"
    fi
    json="[{\"number\":${pr_num},\"user\":{\"login\":${user_val}},\"merged_by\":{\"login\":${merger_val}},\"merged_at\":${merged_at_val}}]"
  fi

  found_jq=false
  for arg in "$@"; do
    if [ "${found_jq}" = true ]; then
      if [ -n "${MOCK_FAIL_ATTEMPTS:-}" ]; then
        count=0
        if [ -f "${TMP_DIR}/gh_attempts" ]; then
          count=$(cat "${TMP_DIR}/gh_attempts")
        fi
        count=$((count + 1))
        echo "$count" > "${TMP_DIR}/gh_attempts"
        if [ "$count" -le "$MOCK_FAIL_ATTEMPTS" ]; then
          echo "||"
          exit 0
        fi
      fi
      if [ "${MOCK_PR_MERGED:-true}" = "false" ]; then
        echo "||"
        exit 0
      fi
      if [ -n "${MOCK_PR_USER:-}" ] || [ -n "${MOCK_PR_MERGER:-}" ]; then
        echo "${MOCK_PR_NUM:-123}|${MOCK_PR_MERGER:-}|${MOCK_PR_USER:-}"
      else
        echo "||"
      fi
      exit 0
    fi
    if [ "$arg" = "--jq" ]; then
      found_jq=true
    fi
  done

  echo "$json"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' "$@" > "${TMP_DIR}/gh_issue_list_args"
  state=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--state" ]; then
      state="$arg"
    fi
    prev="$arg"
  done
  if [ "$state" = "open" ]; then
    if [ -f "${TMP_DIR}/mock_open_issues" ]; then
      cat "${TMP_DIR}/mock_open_issues"
    fi
    exit 0
  fi
  echo "mock-gh: issue list requires --state open" >&2
  exit 1
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  num="${3:-}"
  body=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--body" ]; then
      body="$arg"
    fi
    if [ "$arg" = "--assignee" ] || [ "$arg" = "--label" ]; then
      echo "mock-gh: comment must not set ${arg}" >&2
      exit 1
    fi
    prev="$arg"
  done
  printf '%s' "$body" > "${TMP_DIR}/gh_comment_body"
  printf '%s\n' "$@" > "${TMP_DIR}/gh_comment_args"
  echo "https://github.com/${GITHUB_REPOSITORY:-bcgov/actions}/issues/${num}#issuecomment-1"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  body=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--body" ]; then
      body="$arg"
    fi
    prev="$arg"
  done
  printf '%s' "$body" > "${TMP_DIR}/gh_create_body"
  printf '%s\n' "$@" > "${TMP_DIR}/gh_create_args"
  echo "https://github.com/${GITHUB_REPOSITORY:-local/repo}/issues/77"
  exit 0
fi

# Fallback for unexpected calls
echo "mock-gh: $*" >&2
exit 1
EOF
chmod +x "${MOCK_BIN}/gh"

run_action() {
  local workdir="$1"
  shift
  local out_file="${TMP_DIR}/output.env"
  rm -f "$out_file" \
    "${TMP_DIR}/gh_issue_list_args" \
    "${TMP_DIR}/gh_create_args" \
    "${TMP_DIR}/gh_create_body" \
    "${TMP_DIR}/gh_comment_args" \
    "${TMP_DIR}/gh_comment_body"

  (
    cd "$workdir"
    env \
      PATH="${MOCK_BIN}:${PATH}" \
      TMP_DIR="${TMP_DIR}" \
      GITHUB_OUTPUT="$out_file" \
      GITHUB_EVENT_NAME="push" \
      "$@" \
      bash "$ACTION_SH" 2>&1
  )
}

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $name"
    passed=$((passed + 1))
  else
    echo "✗ $name"
    echo "  Expected: '$expected'"
    echo "  Actual:   '$actual'"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "✓ $name"
    passed=$((passed + 1))
  else
    echo "✗ $name"
    echo "  Expected output to contain: '$needle'"
    echo "  Actual output: '$haystack'"
    failed=$((failed + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "✓ $name"
    passed=$((passed + 1))
  else
    echo "✗ $name"
    echo "  Expected output NOT to contain: '$needle'"
    echo "  Actual output: '$haystack'"
    failed=$((failed + 1))
  fi
}

echo "Running workflow-notifier unit tests..."
echo ""

# Setup workspace with CODEOWNERS
FIXTURE_DIR="${TMP_DIR}/fixture"
mkdir -p "${FIXTURE_DIR}/.github"
cat << 'EOF' > "${FIXTURE_DIR}/.github/CODEOWNERS"
* @alice @bob
EOF

# Test 1: notify_author default ("true") on direct push resolves GITHUB_TRIGGERING_ACTOR
test_notify_author_default() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Default Author" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  assert_contains "$out" "Author:    @charlie" "default notify_author includes author in summary"
  assert_contains "$out" "Assignees: charlie" "default notify_author assigns only author when resolved"
  assert_not_contains "$out" "alice" "excludes CODEOWNERS by default when author resolved"
  assert_contains "$out" "Pushed by @charlie" "direct push sets pushed by note"
}

# Test 2: notify_author="true" with GITHUB_ACTOR fallback when TRIGGERING_ACTOR unset
test_notify_author_actor_fallback() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Actor Fallback" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="" \
    GITHUB_ACTOR="david")

  assert_contains "$out" "Author:    @david" "resolves author via GITHUB_ACTOR fallback"
  assert_contains "$out" "Assignees: david" "assigns fallback author"
}

# Test 3: notify_author="false" falls back to CODEOWNERS
test_notify_author_disabled() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Notify Author Disabled" \
    INPUT_NOTIFY_AUTHOR="false" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  assert_not_contains "$out" "Author:    @charlie" "disabled notify_author omits author from summary"
  assert_contains "$out" "Assignees: alice,bob" "disabled notify_author falls back to CODEOWNERS"
  assert_not_contains "$out" "Pushed by @" "disabled notify_author does not add trigger mention"
}

# Test 4: Bot actors (e.g. dependabot[bot]) are filtered out, falling back to CODEOWNERS
test_bot_filter() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Bot Filter" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="dependabot[bot]")

  assert_not_contains "$out" "dependabot[bot]" "filters out bot actor"
  assert_contains "$out" "Assignees: alice,bob" "falls back to CODEOWNERS when bot filtered"
  assert_not_contains "$out" "Pushed by @" "does not add trigger mention for bot"
}

# Test 5: Author deduplication when notify_codeowners="true" and author is in CODEOWNERS
test_author_dedup() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Author Deduplication" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_NOTIFY_CODEOWNERS="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="alice")

  assert_contains "$out" "Author:    @alice" "identifies alice as author"
  assert_contains "$out" "Assignees: alice,bob" "deduplicates alice in assignees list"
  assert_not_contains "$out" "alice,alice" "no duplicate handle in assignees"
}

# Test 5b: Case-insensitive author deduplication with notify_codeowners="true"
test_author_dedup_case_insensitive() {
  local case_fixture="${TMP_DIR}/case_fixture/.github"
  mkdir -p "$case_fixture"
  cat << 'EOF' > "${case_fixture}/CODEOWNERS"
* @Alice @Bob
EOF

  local out
  out=$(run_action "${TMP_DIR}/case_fixture" \
    INPUT_TITLE="Test Case Insensitive Dedup" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_NOTIFY_CODEOWNERS="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="alice")

  assert_contains "$out" "Author:    @alice" "identifies alice as author"
  assert_contains "$out" "Assignees: alice,Bob" "deduplicates Alice case-insensitively"
  assert_not_contains "$out" "Alice," "removes previous uppercase case variant from assignees list"
}

# Test 6: Fallback to PR lookup via gh api on merge commit
test_pr_api_fallback() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test PR API Fallback" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DEBUG="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    GITHUB_TRIGGERING_ACTOR="github-actions[bot]" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_PR_USER="pr-creator" \
    MOCK_PR_MERGER="pr-merger")

  assert_contains "$out" "Author:    @pr-merger" "resolves merger from PR lookup"
  assert_contains "$out" "Author:    @pr-creator" "resolves creator from PR lookup"
  assert_contains "$out" "Assignees: pr-merger,pr-creator" "assigns PR merger and creator"
  assert_contains "$out" "Merged by @pr-merger" "mentions PR merger in body"
  assert_contains "$out" "Authored by @pr-creator" "mentions PR creator in body"
}

# Test 6b: PR merger and author included on rerun
test_pr_merger_priority_over_rerunner() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test PR Merger Priority" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DEBUG="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    GITHUB_TRIGGERING_ACTOR="rerun-actor" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_PR_USER="pr-author" \
    MOCK_PR_MERGER="original-merger")

  assert_contains "$out" "Author:    @original-merger" "prioritizes original PR merger"
  assert_contains "$out" "Author:    @pr-author" "includes PR author"
  assert_contains "$out" "Assignees: original-merger,pr-author" "assigns both original merger and PR author"
}

# Test 6c: Bot merger falls back to human PR author
test_pr_bot_merger_falls_back_to_pr_author() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Bot Merger Fallback" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    GITHUB_TRIGGERING_ACTOR="dependabot[bot]" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_PR_USER="human-author" \
    MOCK_PR_MERGER="dependabot[bot]")

  assert_contains "$out" "Author:    @human-author" "falls back to human PR author when PR merged by bot"
  assert_contains "$out" "Assignees: human-author" "assigns human PR author"
  assert_not_contains "$out" "dependabot[bot]" "excludes bot merger"
}

# Test 6d: Same author and merger yields consolidated note
test_pr_same_author_and_merger() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Same Author Merger" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    GITHUB_TRIGGERING_ACTOR="solo-dev" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_PR_USER="solo-dev" \
    MOCK_PR_MERGER="solo-dev")

  assert_contains "$out" "Merged and authored by @solo-dev" "consolidates note when author and merger match"
  assert_contains "$out" "Assignees: solo-dev" "assigns single handle when author matches merger"
}

# Test 6e: notify_codeowners="true" includes CODEOWNERS alongside PR author/merger
test_notify_codeowners_always() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Codeowners Always" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_NOTIFY_CODEOWNERS="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    GITHUB_TRIGGERING_ACTOR="merger1" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_PR_USER="author1" \
    MOCK_PR_MERGER="merger1")

  assert_contains "$out" "Assignees: merger1,author1,alice,bob" "includes actors and CODEOWNERS when notify_codeowners is true"
}

# Test 7: Assignees when no CODEOWNERS exists
test_no_codeowners() {
  local empty_fixture="${TMP_DIR}/empty_fixture"
  mkdir -p "$empty_fixture"

  local out
  out=$(run_action "$empty_fixture" \
    INPUT_TITLE="Test No CODEOWNERS" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="solouser")

  assert_contains "$out" "Author:    @solouser" "identifies solouser"
  assert_contains "$out" "Assignees: solouser" "assignees contains only solouser when no CODEOWNERS"
}

# Test 7b: notify_codeowners="false" excludes CODEOWNERS even on scheduled runs
test_notify_codeowners_disabled() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test CODEOWNERS Disabled" \
    INPUT_EVENT_NAME="schedule" \
    INPUT_NOTIFY_CODEOWNERS="false" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true")

  assert_contains "$out" "Assignees: " "assignees is empty when CODEOWNERS disabled on schedule"
  assert_not_contains "$out" "alice" "excludes CODEOWNERS handle alice"
  assert_not_contains "$out" "bob" "excludes CODEOWNERS handle bob"
}

# Test 7c: notify_codeowners="false" and notify_author="false" yields empty assignees
test_notify_all_disabled() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test All Notifications Disabled" \
    INPUT_NOTIFY_CODEOWNERS="false" \
    INPUT_NOTIFY_AUTHOR="false" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  assert_not_contains "$out" "Author:    @" "no author in summary"
  assert_contains "$out" "Assignees: " "assignees is empty"
  assert_not_contains "$out" "charlie" "charlie not assigned"
  assert_not_contains "$out" "alice" "alice not assigned"
}

# Test 8: Event workflow_dispatch assigns operator and sets note
test_workflow_dispatch_event() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Workflow Dispatch" \
    INPUT_EVENT_NAME="workflow_dispatch" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="operator1")

  assert_contains "$out" "Author:    @operator1" "identifies operator"
  assert_contains "$out" "Assignees: operator1" "assigns operator"
  assert_contains "$out" "Dispatched by @operator1" "sets dispatched by note"
  assert_not_contains "$out" "alice" "excludes CODEOWNERS on dispatch by default"
}

# Test 9: Event schedule sets scheduled automation note and falls back to CODEOWNERS
test_schedule_event() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Schedule Event" \
    INPUT_EVENT_NAME="schedule" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="github-actions[bot]")

  assert_contains "$out" "Triggered by scheduled automation" "sets scheduled automation note"
  assert_contains "$out" "Assignees: alice,bob" "falls back to CODEOWNERS on schedule"
  assert_not_contains "$out" "Author:    @" "no human author on schedule"
}

# Test 10: GitHub 10-assignee limit handling
test_ten_assignee_limit() {
  local many_fixture="${TMP_DIR}/many_fixture/.github"
  mkdir -p "$many_fixture"
  cat << 'EOF' > "${many_fixture}/CODEOWNERS"
* @u01 @u02 @u03 @u04 @u05 @u06 @u07 @u08 @u09 @u10 @u11 @u12
EOF

  local out
  out=$(run_action "${TMP_DIR}/many_fixture" \
    INPUT_TITLE="Test 10 Limit" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_NOTIFY_CODEOWNERS="true" \
    INPUT_DRY_RUN="true" \
    INPUT_ASSIGN="true" \
    GITHUB_TRIGGERING_ACTOR="leadauthor")

  assert_contains "$out" "--assignee leadauthor,u01,u02,u03,u04,u05,u06,u07,u08,u09" \
    "caps --assignee argument at 10 with author first"
  assert_contains "$out" "Assignees: leadauthor,u01,u02,u03,u04,u05,u06,u07,u08,u09" \
    "caps summary assignees output at 10"
  local out_env
  out_env=$(cat "${TMP_DIR}/output.env")
  assert_contains "$out_env" "assignees=leadauthor,u01,u02,u03,u04,u05,u06,u07,u08,u09" \
    "clamps step output assignees to 10"
  assert_not_contains "$out_env" "u10" "excludes 11th owner from step output"
}

# Test 11: PR lookup retries on indexing lag and recovers
test_pr_api_retry_success() {
  rm -f "${TMP_DIR}/gh_attempts"
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test PR API Retry" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    INPUT_EVENT_NAME="push" \
    GITHUB_TRIGGERING_ACTOR="github-actions[bot]" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_FAIL_ATTEMPTS="1" \
    MOCK_PR_USER="pr-creator" \
    MOCK_PR_MERGER="pr-merger")

  assert_contains "$out" "Author:    @pr-merger" "retries and resolves merger from PR lookup"
  assert_contains "$out" "Author:    @pr-creator" "retries and resolves creator from PR lookup"
  assert_contains "$out" "Merged by @pr-merger" "mentions PR merger in body after retry"
}

# Test 12: Event pull_request uses neutral Triggered by wording instead of Pushed by / Merged by
test_pull_request_event() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Pull Request Event" \
    INPUT_EVENT_NAME="pull_request" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="pr-reviewer")

  assert_contains "$out" "Author:    @pr-reviewer" "identifies PR triggering actor"
  assert_contains "$out" "Assignees: pr-reviewer" "assigns PR triggering actor"
  assert_contains "$out" "Triggered by @pr-reviewer" "sets neutral Triggered by note on pull_request"
  assert_not_contains "$out" "Pushed by" "does not label pull_request as pushed by"
  assert_not_contains "$out" "Merged by" "does not label pull_request as merged by"
}

# Test 13: Push to branch with an open, unmerged PR ignores unmerged PR and falls back to actor
test_push_to_branch_with_open_unmerged_pr() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Unmerged PR Branch Push" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    INPUT_TOKEN="dummy-token" \
    INPUT_EVENT_NAME="push" \
    GITHUB_TRIGGERING_ACTOR="branch-pusher" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SHA="1234567890abcdef" \
    MOCK_PR_USER="pr-opener" \
    MOCK_PR_MERGER="branch-pusher" \
    MOCK_PR_MERGED="false")

  assert_contains "$out" "Author:    @branch-pusher" "identifies branch pusher as author"
  assert_not_contains "$out" "pr-opener" "does not include unmerged PR author"
  assert_contains "$out" "Pushed by @branch-pusher" "uses Pushed by note instead of Merged by"
  assert_not_contains "$out" "Merged by" "does not label unmerged PR as merged"
}

test_notify_author_default
test_notify_author_actor_fallback
test_notify_author_disabled
test_bot_filter
test_author_dedup
test_author_dedup_case_insensitive
test_pr_api_fallback
test_pr_merger_priority_over_rerunner
test_pr_bot_merger_falls_back_to_pr_author
test_pr_same_author_and_merger
test_notify_codeowners_always
test_no_codeowners
test_notify_codeowners_disabled
test_notify_all_disabled
test_workflow_dispatch_event
test_schedule_event
test_ten_assignee_limit
test_pr_api_retry_success
test_pull_request_event
test_push_to_branch_with_open_unmerged_pr

# One open issue per exact title. Later runs comment; they do not edit the body.
reset_issue_fixtures() {
  rm -f "${TMP_DIR}/mock_open_issues"
}

run_line() {
  local run_id="$1"
  printf -- '- 2026-09-22T20:39:12Z — [run](https://github.com/bcgov/actions/actions/runs/%s)' "$run_id"
}

assert_file_absent() {
  local file="$1" name="$2"
  if [ ! -f "$file" ]; then
    echo "✓ $name"
    passed=$((passed + 1))
  else
    echo "✗ $name"
    echo "  Expected file to be absent: $file"
    failed=$((failed + 1))
  fi
}

test_create_when_no_open_match() {
  reset_issue_fixtures
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="TEST Deployment Failure: api" \
    INPUT_BODY="Boom" \
    INPUT_LABELS="bug, failure" \
    INPUT_ASSIGN="true" \
    INPUT_TOKEN="dummy-token" \
    INPUT_DRY_RUN="false" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_RUN_ID="123" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  local body list_args create_args
  body="$(cat "${TMP_DIR}/gh_create_body")"
  list_args="$(cat "${TMP_DIR}/gh_issue_list_args")"
  create_args="$(cat "${TMP_DIR}/gh_create_args")"

  assert_contains "$out" "Issue:     #77" "create path returns the new issue number"
  assert_contains "$list_args" $'--state\nopen' "lists open issues only"
  assert_contains "$list_args" $'--limit\n100' "scans at most 100 open issues"
  assert_contains "$create_args" "--label" "create adds labels"
  assert_contains "$create_args" "bug" "create adds the bug label"
  assert_contains "$create_args" "failure" "create adds the failure label"
  assert_contains "$create_args" "--assignee" "create assigns owners"
  assert_contains "$create_args" "charlie" "create assigns the resolved author"
  assert_contains "$body" "Boom" "create keeps the caller body"
  assert_contains "$body" "Pushed by @charlie" "create keeps the trigger note"
  assert_contains "$body" "[View Workflow Run](https://github.com/bcgov/actions/actions/runs/123)" "create keeps the workflow link"
  assert_file_absent "${TMP_DIR}/gh_comment_body" "create does not comment"
}

test_comment_on_exact_title() {
  reset_issue_fixtures
  printf '%s\n' $'40\tTEST Deployment Failure: api' $'12\tTEST Deployment Failure: api' \
    $'99\tTEST Deployment Failure: api extra' \
    > "${TMP_DIR}/mock_open_issues"

  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="TEST Deployment Failure: api" \
    INPUT_BODY="Boom" \
    INPUT_LABELS="bug,failure" \
    INPUT_ASSIGN="true" \
    INPUT_TOKEN="dummy-token" \
    INPUT_DRY_RUN="false" \
    GITHUB_REPOSITORY="bcgov/actions" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_RUN_ID="456" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  local body comment_args
  body="$(cat "${TMP_DIR}/gh_comment_body")"
  comment_args="$(cat "${TMP_DIR}/gh_comment_args")"

  assert_contains "$out" "Issue:     #40" "comment path returns the first exact title match"
  assert_eq "$body" "$(run_line 456)" "comment body is the run line"
  assert_not_contains "$comment_args" "--assignee" "comment does not assign"
  assert_not_contains "$comment_args" "--label" "comment does not set labels"
  assert_file_absent "${TMP_DIR}/gh_create_body" "comment does not create another issue"
}

test_create_when_no_open_match
test_comment_on_exact_title

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
