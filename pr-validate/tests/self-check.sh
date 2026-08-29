#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../fork-notice.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fork-notice.sh"

passed=0
failed=0

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label"
    failed=$((failed + 1))
  fi
}

msg="$(fork_pr_warning)"
assert_contains "$msg" "read-only tokens" "warning mentions read-only tokens"
assert_contains "$msg" "README.md#fork-pull-requests" "warning links to fork docs"

echo ""
echo "Passed: $passed, Failed: $failed"
[[ "$failed" -eq 0 ]]
