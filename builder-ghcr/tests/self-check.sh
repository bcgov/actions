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

assert_empty "$(refuse_reason push bcgov/actions '')" "push is allowed"
assert_empty "$(refuse_reason push fork/actions '')" "push on a fork is allowed"
assert_empty "$(refuse_reason pull_request bcgov/actions bcgov/actions)" "same-repo PR is allowed"
assert_empty "$(refuse_reason pull_request BcGov/Actions bcgov/actions)" "same-repo PR compare is case-insensitive"
assert_empty "$(refuse_reason workflow_dispatch bcgov/actions '')" "workflow_dispatch is allowed"
assert_empty "$(refuse_reason merge_group bcgov/actions '')" "merge_group is allowed"

fork_pr="$(refuse_reason pull_request bcgov/actions fork/actions)"
assert_contains "$fork_pr" "cannot push from a fork pull_request" "fork PR against base is refused"
assert_contains "$fork_pr" "ghcr.io/fork/actions" "fork PR message names the fork registry"
assert_contains "$fork_pr" "builder-ghcr/README.md#fork-builds" "fork PR message links to docs"

fork_prt="$(refuse_reason pull_request_target bcgov/actions fork/actions)"
assert_contains "$fork_prt" "refuses pull_request_target" "fork pull_request_target is refused"
assert_contains "$fork_prt" "untrusted" "pull_request_target message names the trust issue"
assert_contains "$fork_prt" "builder-ghcr/README.md#fork-builds" "pull_request_target message links to docs"

msg="$(fork_visibility_message bcgov/actions/backend abcdef)"
assert_contains "$msg" "ImagePullBackOff" "visibility message names the deploy symptom"
assert_contains "$msg" "ghcr.io/bcgov/actions/backend:abcdef" "visibility message names the image"
assert_contains "$msg" "Change visibility" "visibility message names the fix"
assert_contains "$msg" "builder-ghcr/README.md#fork-builds" "visibility message links to docs"

assert_eq "$(is_fork_repository true && echo yes || echo no)" "yes" "is_fork_repository true"
assert_eq "$(is_fork_repository false && echo yes || echo no)" "no" "is_fork_repository false"

assert_empty "$(refuse_reason pull_request_target bcgov/actions bcgov/actions)" \
  "same-repo pull_request_target is allowed"

echo ""
echo "Passed: ${passed}, Failed: ${failed}"
[ "$failed" -eq 0 ]
