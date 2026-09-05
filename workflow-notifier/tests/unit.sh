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
    json="[{\"number\":${pr_num},\"user\":{\"login\":${user_val}},\"merged_by\":{\"login\":${merger_val}}}]"
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

# Fallback for unexpected calls
echo "mock-gh: $*" >&2
exit 1
EOF
chmod +x "${MOCK_BIN}/gh"

run_action() {
  local workdir="$1"
  shift
  local out_file="${TMP_DIR}/output.env"
  rm -f "$out_file"

  (
    cd "$workdir"
    env \
      PATH="${MOCK_BIN}:${PATH}" \
      TMP_DIR="${TMP_DIR}" \
      GITHUB_OUTPUT="$out_file" \
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
    INPUT_RETRY_DELAY="0" \
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

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
