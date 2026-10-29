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

mv "$fixture/.github/workflows/ok.yml" "$fixture/.github/workflows/.hidden.yml"
set +e
ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" bash "$lint" >/tmp/pr-validate-hidden.txt 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]] && grep -q "evnet" /tmp/pr-validate-hidden.txt; then
  echo "ok  hidden workflow file is linted"
  passed=$((passed + 1))
else
  echo "FAIL  hidden workflow file is linted"
  cat /tmp/pr-validate-hidden.txt
  failed=$((failed + 1))
fi
rm "$fixture/.github/workflows/.hidden.yml"

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

# Runner labels: bundled ubuntu-26.04 labels, plus the caller's own labels.
lint_fixture() { # expected-status label
  local expected="$1" label="$2" status
  set +e
  ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" RUNNER_TEMP="$fixture" bash "$lint" >/tmp/pr-validate-labels.txt 2>&1
  status=$?
  set -e
  if { [[ "$expected" == pass ]] && [[ "$status" -eq 0 ]]; } ||
    { [[ "$expected" == fail ]] && [[ "$status" -ne 0 ]] && grep -q 'is unknown' /tmp/pr-validate-labels.txt; }; then
    echo "ok  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label"
    cat /tmp/pr-validate-labels.txt
    failed=$((failed + 1))
  fi
}

cat > "$fixture/.github/workflows/ok.yml" <<'EOF'
name: labels
on: push
jobs:
  amd64:
    runs-on: ubuntu-26.04
    steps:
      - uses: $/pr-validate
  arm64:
    runs-on: ubuntu-26.04-arm
    steps:
      - run: echo ok
EOF
lint_fixture pass "ubuntu-26.04 and ubuntu-26.04-arm are known runner labels"

cat >> "$fixture/.github/workflows/ok.yml" <<'EOF'
  custom:
    runs-on: [self-hosted, my-runner, quoted-runner]
    steps:
      - run: echo ok
EOF
lint_fixture fail "unknown runner label fails without a caller config"

config_before="$(cat "$config")"
cat > "$fixture/.github/actionlint.yaml" <<'EOF'
# caller config, block list
self-hosted-runner:
  labels:
    - my-runner # comment
    - "quoted-runner"
paths:
  '**/*.yml':
    ignore:
      - 'anything'
EOF
lint_fixture pass "caller .github/actionlint.yaml labels are added to the bundled ones"
merged="$fixture/pr-validate-actionlint.yaml"
if grep -q 'my-runner' "$merged" && grep -q 'quoted-runner' "$merged" &&
  grep -q 'ubuntu-26.04-arm' "$merged" && grep -q 'specifying action' "$merged" &&
  ! grep -q 'anything' "$merged" && [[ "$(cat "$config")" == "$config_before" ]]; then
  echo "ok  merged config keeps the bundled labels and ignores, bundled file unchanged"
  passed=$((passed + 1))
else
  echo "FAIL  merged config keeps the bundled labels and ignores, bundled file unchanged"
  cat "$merged"
  failed=$((failed + 1))
fi
rm "$fixture/.github/actionlint.yaml"

printf 'self-hosted-runner:\n  labels: [quoted-runner, "my-runner"] # flow list\n' > "$fixture/.github/actionlint.yml"
lint_fixture pass "caller .github/actionlint.yml flow-list labels are added"

printf 'self-hosted-runner:\n  labels:\n    - quoted-runner\n    - "my-*"\n' > "$fixture/.github/actionlint.yml"
lint_fixture pass "caller glob pattern label matches"

printf 'self-hosted-runner:\n  labels:\n    - other-runner\n' > "$fixture/.github/actionlint.yml"
lint_fixture fail "caller config without the label still fails"
rm "$fixture/.github/actionlint.yml"

# Shared list inputs for bcgov/actions* callers: old formats fail, one per line passes.
list_fail() { # label input-line(s)
  local label="$1" body="$2" status
  printf 'name: lists\non: push\njobs:\n  build:\n    runs-on: ubuntu-26.04\n    steps:\n      - uses: bcgov/actions/image-tracker@v0.11.0\n        with:\n%s\n' "$body" > "$fixture/.github/workflows/ok.yml"
  set +e
  ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" RUNNER_TEMP="$fixture" bash "$lint" >/tmp/pr-validate-lists.txt 2>&1
  status=$?
  set -e
  if [[ "$status" -ne 0 ]] && grep -q 'list format' /tmp/pr-validate-lists.txt; then
    echo "ok  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label"
    cat /tmp/pr-validate-lists.txt
    failed=$((failed + 1))
  fi
}
list_fail "comma-separated triggers fail" "          triggers: backend/, frontend/"
list_fail "space-separated triggers fail" "          triggers: 'backend/ frontend/'"
list_fail "bash-array triggers fail" "          triggers: ('backend/' 'frontend/')"
list_fail "JSON triggers fail" '          triggers: "[\"backend/\", \"frontend/\"]"'
list_fail "bracket list in a block fails" "          triggers: |
            [backend/, frontend/]"
list_fail "folded block (>) triggers fail" "          triggers: >
            backend/
            frontend/"
list_fail "space-separated packages fail" "          packages: api frontend # comment"
list_fail "space-separated package fails" '          package: "api frontend"'
list_fail "comma-separated tags fail" "          tags: latest,prod"
list_fail "space-separated keep_digests fail" "          keep_digests: sha256:aaa sha256:bbb"
list_fail "space-separated components fail" "          components: backend frontend"
list_fail "comma-separated hosts fail" "          hosts: a.example.com,b.example.com"
list_fail "space-separated cleanup_name fails" "          cleanup_name: app db"
list_fail "comma-separated remove_pvc fails" "          remove_pvc: data,logs"

# cert-expiry strips '# comments' from each hosts line before reading the list.
cat > "$fixture/.github/workflows/ok.yml" <<'EOF'
name: lists
on: push
jobs:
  certs:
    runs-on: ubuntu-24.04
    steps:
      - uses: bcgov/actions-openshift/cert-expiry@v1
        with:
          hosts: |
            a.example.com # production endpoint
            b.example.com
EOF
set +e
ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" RUNNER_TEMP="$fixture" bash "$lint" >/tmp/pr-validate-lists.txt 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "ok  commented hosts block passes"
  passed=$((passed + 1))
else
  echo "FAIL  commented hosts block passes"
  cat /tmp/pr-validate-lists.txt
  failed=$((failed + 1))
fi

# Reusable workflow with `with:` written before `uses:`.
cat > "$fixture/.github/workflows/ok.yml" <<'EOF'
name: lists
on: push
jobs:
  close:
    with:
      packages: api frontend
    permissions:
      packages: write
    uses: bcgov/actions-openshift/.github/workflows/.pr-close.yml@v0.6.0
EOF
set +e
ACTIONLINT_CONFIG="$config" ACTIONLINT_WORKSPACE="$fixture" RUNNER_TEMP="$fixture" bash "$lint" >/tmp/pr-validate-lists.txt 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]] && grep -q 'packages: list format' /tmp/pr-validate-lists.txt; then
  echo "ok  with: before uses: is checked"
  passed=$((passed + 1))
else
  echo "FAIL  with: before uses: is checked"
  cat /tmp/pr-validate-lists.txt
  failed=$((failed + 1))
fi

cat > "$fixture/.github/workflows/ok.yml" <<'EOF'
name: lists
on: push
jobs:
  close:
    uses: bcgov/actions-openshift/.github/workflows/.pr-close.yml@v0.6.0
    permissions:
      packages: write
    with:
      packages: |
        api
        frontend
  build:
    runs-on: ubuntu-26.04
    strategy:
      matrix:
        package: [api, frontend]
    steps:
      - uses: bcgov/actions/diff-triggers@v0.11.0
        with:
          triggers: |
            backend/
            'my path/'
            src/{a,b}/**
            ${{ vars.EXTRA_TRIGGER }}
      - uses: bcgov/actions/builder@v0.11.0
        with:
          package: ${{ matrix.package }}
          triggers: ${{ toJSON(fromJSON('["a/", "b/"]')) }}
          tags: latest
      - uses: bcgov/actions/image-tracker@v0.11.0
        with:
          package: "${{ matrix.package }}"
      - uses: bcgov/actions/image-tracker@v0.11.0
        with:
          package: app-${{ matrix.package }}
      - with:
          keep_digests: |
            sha256:aaa
            sha256:bbb
        uses: bcgov/actions/ghcr-cleanup@v0.11.0
      - uses: bcgov/actions/image-tracker@v0.11.0
        with:
          package: backend   
      - run: echo ok
        env:
          packages: curl jq
      - uses: example/apt-install@v1
        with:
          packages: curl jq
          tags: a, b
EOF
lint_fixture pass "one item per line, single values, expressions and other actions pass"

rm -rf "$fixture"

echo ""
echo "Passed: $passed, Failed: $failed"
[[ "$failed" -eq 0 ]]
