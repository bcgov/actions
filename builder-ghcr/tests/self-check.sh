#!/usr/bin/env bash
# Offline checks for builder-ghcr image targeting (fork/push contract).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../context.sh
source "${SCRIPT_DIR}/../context.sh"

passed=0
failed=0

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" = "$expected" ]; then
    echo "ok  $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    echo "  expected: '$expected'"
    echo "  actual:   '$actual'"
    failed=$((failed + 1))
  fi
}

assert_empty() {
  local actual="$1" name="$2"
  assert_eq "$actual" "" "$name"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok  $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    echo "  expected to contain: '$needle'"
    echo "  actual: '$haystack'"
    failed=$((failed + 1))
  fi
}

assert_eq "$(image_path_for backend bcgov/actions actions)" "bcgov/actions/backend" \
  "multi-package image path"
assert_eq "$(image_path_for actions bcgov/actions actions)" "bcgov/actions" \
  "single-package image path when package matches repo name"
assert_eq "$(image_path_for Backend BcGov/Actions Actions)" "bcgov/actions/backend" \
  "image path is lowercased"

assert_eq "$(source_sha abcdef githubsha)" "abcdef" "source_sha prefers PR head"
assert_eq "$(source_sha '' githubsha)" "githubsha" "source_sha falls back to github.sha"

assert_eq "$(merge_sha_tag $'123\n' abcdef)" $'123\nabcdef' "merge_sha_tag appends SHA"
assert_eq "$(merge_sha_tag $'abcdef\n123\n' abcdef)" $'abcdef\n123' "merge_sha_tag does not duplicate SHA"
assert_eq "$(merge_sha_tag '' abcdef)" "abcdef" "merge_sha_tag works when tags are empty (push)"
assert_eq "$(merge_sha_tag $'PR-123\n' ABCDEF)" $'pr-123\nabcdef' "merge_sha_tag lowercases"

assert_eq "$(publish_repository push bcgov/actions '')" "bcgov/actions" "push publishes to workflow repo"
assert_eq "$(publish_repository pull_request bcgov/actions bcgov/actions)" "bcgov/actions" "same-repo PR publishes to workflow repo"
assert_eq "$(publish_repository pull_request bcgov/actions fork/actions)" "fork/actions" "fork PR targets fork GHCR"
assert_eq "$(publish_repository push fork/actions '')" "fork/actions" "fork push targets fork GHCR"

can_push_packages push bcgov/actions '' && assert_eq "$?" "0" "push can publish"
can_push_packages pull_request bcgov/actions bcgov/actions && assert_eq "$?" "0" "same-repo PR can publish"
if can_push_packages pull_request bcgov/actions fork/actions; then
  echo "FAIL  fork PR cannot publish"
  failed=$((failed + 1))
else
  echo "ok  fork PR cannot publish"
  passed=$((passed + 1))
fi

assert_empty "$(refuse_reason push bcgov/actions '')" "push is allowed"
assert_empty "$(refuse_reason pull_request bcgov/actions fork/actions)" "fork pull_request is allowed"
assert_empty "$(refuse_reason pull_request bcgov/actions bcgov/actions)" "same-repo PR is allowed"
assert_empty "$(refuse_reason workflow_dispatch bcgov/actions '')" "workflow_dispatch is allowed"

fork_prt="$(refuse_reason pull_request_target bcgov/actions fork/actions)"
assert_contains "$fork_prt" "refuses pull_request_target" "fork pull_request_target is refused"
assert_contains "$fork_prt" "pull_request workflow instead" "pull_request_target message steers to pull_request"
assert_contains "$fork_prt" "builder-ghcr/README.md#fork-builds" "pull_request_target message links to docs"

assert_empty "$(refuse_reason pull_request_target bcgov/actions bcgov/actions)" \
  "same-repo pull_request_target is allowed"

msg="$(fork_visibility_message)"
assert_contains "$msg" "Images built from forks require" "visibility message states the requirement"
assert_contains "$msg" "package visibility to public" "visibility message names the fix"
assert_contains "$msg" "builder-ghcr/README.md#fork-builds" "visibility message links to docs"

pr_msg="$(fork_pr_publish_message bcgov/actions/backend abcdef)"
assert_contains "$pr_msg" "Fork pull_request cannot push" "fork PR notice explains read-only"
assert_contains "$pr_msg" "ghcr.io/bcgov/actions/backend:abcdef" "fork PR notice names the image"
assert_contains "$pr_msg" "push to your fork" "fork PR notice points to fork push"

assert_eq "$(is_fork_repository true && echo yes || echo no)" "yes" "is_fork_repository true"
assert_eq "$(is_fork_repository false && echo yes || echo no)" "no" "is_fork_repository false"

echo ""
echo "Passed: ${passed}, Failed: ${failed}"
[ "$failed" -eq 0 ]
