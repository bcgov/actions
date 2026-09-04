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
  if [[ "$*" == *"--jq"* ]]; then
    if [ -n "${MOCK_PR_MERGER:-}" ]; then
      echo "${MOCK_PR_MERGER}"
    elif [ -n "${MOCK_PR_USER:-}" ]; then
      echo "${MOCK_PR_USER}"
    fi
    exit 0
  fi
  if [ -n "${MOCK_PR_USER:-}" ]; then
    echo "[{\"user\":{\"login\":\"${MOCK_PR_USER}\"},\"merged_by\":{\"login\":\"${MOCK_PR_MERGER:-}\"}}]"
    exit 0
  else
    echo "[]"
    exit 0
  fi
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

# Test 1: notify_author default ("true") resolves GITHUB_TRIGGERING_ACTOR
test_notify_author_default() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Default Author" \
    INPUT_DEBUG="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  assert_contains "$out" "Author:    @charlie" "default notify_author includes author in summary"
  assert_contains "$out" "Assignees: charlie,alice,bob" "default notify_author prepends author to assignees"
  assert_contains "$out" "Triggered by @charlie" "default notify_author adds mention to body"
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
  assert_contains "$out" "Assignees: david,alice,bob" "prepends fallback author to assignees"
}

# Test 3: notify_author="false" excludes author from assignees and body
test_notify_author_disabled() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Notify Author Disabled" \
    INPUT_NOTIFY_AUTHOR="false" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="charlie")

  assert_not_contains "$out" "Author:    @charlie" "disabled notify_author omits author from summary"
  assert_contains "$out" "Assignees: alice,bob" "disabled notify_author preserves CODEOWNERS assignees only"
  assert_not_contains "$out" "Triggered by @" "disabled notify_author does not add trigger mention"
}

# Test 4: Bot actors (e.g. dependabot[bot]) are filtered out
test_bot_filter() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Bot Filter" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="dependabot[bot]")

  assert_not_contains "$out" "dependabot[bot]" "filters out bot actor"
  assert_contains "$out" "Assignees: alice,bob" "preserves CODEOWNERS without bot"
  assert_not_contains "$out" "Triggered by @" "does not add trigger mention for bot"
}

# Test 5: Author deduplication when author already exists in CODEOWNERS
test_author_dedup() {
  local out
  out=$(run_action "$FIXTURE_DIR" \
    INPUT_TITLE="Test Author Deduplication" \
    INPUT_NOTIFY_AUTHOR="true" \
    INPUT_DRY_RUN="true" \
    GITHUB_TRIGGERING_ACTOR="alice")

  assert_contains "$out" "Author:    @alice" "identifies alice as author"
  assert_contains "$out" "Assignees: alice,bob" "deduplicates alice in assignees list"
  assert_not_contains "$out" "alice,alice" "no duplicate handle in assignees"
}

# Test 6: Fallback to PR lookup via gh api when actor is empty or bot
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
  assert_contains "$out" "Assignees: pr-merger,alice,bob" "includes PR merger in assignees"
  assert_contains "$out" "Triggered by @pr-merger" "mentions PR merger in body"
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

# Test 8: GitHub 10-assignee limit handling
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
    INPUT_DRY_RUN="true" \
    INPUT_ASSIGN="true" \
    GITHUB_TRIGGERING_ACTOR="leadauthor")

  assert_contains "$out" "--assignee leadauthor,u01,u02,u03,u04,u05,u06,u07,u08,u09" \
    "caps --assignee argument at 10 with author first"
}

test_notify_author_default
test_notify_author_actor_fallback
test_notify_author_disabled
test_bot_filter
test_author_dedup
test_pr_api_fallback
test_no_codeowners
test_ten_assignee_limit

echo ""
echo "Unit tests finished: ${passed} passed, ${failed} failed."

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
