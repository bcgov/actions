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

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$root/.." && pwd)"
lint="$root/lint-workflows.sh"
config="$root/actionlint.yaml"

set +e
ACTIONLINT_VERSION=v0.0.0-missing ACTIONLINT_CONFIG="$config" bash "$lint" >/tmp/pr-validate-missing-bin.txt 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]] && grep -q "actionlint download failed" /tmp/pr-validate-missing-bin.txt; then
  echo "ok  missing actionlint binary fails the step"
  passed=$((passed + 1))
else
  echo "FAIL  missing actionlint binary fails the step"
  failed=$((failed + 1))
fi

fixture="$(mktemp -d)"
git init -q "$fixture"
mkdir -p "$fixture/.github/workflows"
cat > "$fixture/.github/workflows/ok.yml" <<'EOF'
name: ok
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: $/pr-validate
EOF

set +e
ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" bash "$lint" >/tmp/pr-validate-dollar.txt 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "ok  self-repo $/ reference stays green"
  passed=$((passed + 1))
else
  echo "FAIL  self-repo $/ reference stays green"
  cat /tmp/pr-validate-dollar.txt
  failed=$((failed + 1))
fi

cat > "$fixture/.github/workflows/ok.yml" <<'EOF'
name: broken
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ${{ github.evnet }}
EOF

set +e
ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" bash "$lint" >/tmp/pr-validate-syntax.txt 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]] && grep -q "evnet" /tmp/pr-validate-syntax.txt; then
  echo "ok  invalid workflow expression fails the step"
  passed=$((passed + 1))
else
  echo "FAIL  invalid workflow expression fails the step"
  cat /tmp/pr-validate-syntax.txt
  failed=$((failed + 1))
fi

set +e
ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$repo" bash "$lint" >/tmp/pr-validate-repo.txt 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "ok  this repo's workflows stay green"
  passed=$((passed + 1))
else
  echo "FAIL  this repo's workflows stay green"
  cat /tmp/pr-validate-repo.txt
  failed=$((failed + 1))
fi

rm -rf "$fixture"

echo ""
echo "Passed: $passed, Failed: $failed"
[[ "$failed" -eq 0 ]]
