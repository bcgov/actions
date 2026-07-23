#!/usr/bin/env bash
# Unit tests for image-tracker's pure logic (no network).

set -euo pipefail

passed=0
failed=0

assert_eq() {
    local actual="$1"
    local expected="$2"
    local name="$3"
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

# Mirror of the package-path mapping logic in action.sh.
# Populates the associative array IMAGE_PATHS in the caller's scope.
map_packages() {
    local package_input="$1"
    local repository="$2"
    unset IMAGE_PATHS
    declare -gA IMAGE_PATHS
    local repo_name="${repository#*/}"
    local lc_repo="${repository,,}"
    local pkg
    # Normalize separators: turn commas and whitespace into newlines, then read line by line
    while IFS= read -r pkg; do
        pkg="${pkg//[[:space:]]/}"
        [[ -z "$pkg" ]] && continue
        if [[ "${pkg,,}" == "${repo_name,,}" ]]; then
            IMAGE_PATHS["$pkg"]="${lc_repo}"
        else
            IMAGE_PATHS["$pkg"]="${lc_repo}/${pkg,,}"
        fi
    done < <(echo "$package_input" | tr ',' '\n' | tr -s '[:space:]' '\n')
}

test_single_package_nested() {
    map_packages "frontend" "bcgov/quickstart-openshift"
    assert_eq "${#IMAGE_PATHS[@]}" "1" "single package count"
    assert_eq "${IMAGE_PATHS[frontend]}" "bcgov/quickstart-openshift/frontend" \
        "nested path when package != repo"
}

test_single_package_repo_root() {
    map_packages "vexilon" "MinionTech/vexilon"
    assert_eq "${#IMAGE_PATHS[@]}" "1" "repo-root package count"
    assert_eq "${IMAGE_PATHS[vexilon]}" "miniontech/vexilon" \
        "root path when package == repo (case-insensitive)"
}

test_multiple_packages_comma() {
    map_packages "frontend, backend, migrations" "bcgov/quickstart-openshift"
    assert_eq "${#IMAGE_PATHS[@]}" "3" "three packages"
    assert_eq "${IMAGE_PATHS[frontend]}"   "bcgov/quickstart-openshift/frontend"   "frontend path"
    assert_eq "${IMAGE_PATHS[backend]}"    "bcgov/quickstart-openshift/backend"    "backend path"
    assert_eq "${IMAGE_PATHS[migrations]}" "bcgov/quickstart-openshift/migrations" "migrations path"
}

test_multiple_packages_newline() {
    map_packages $'api\nfrontend\ndb' "bcgov/myapp"
    assert_eq "${#IMAGE_PATHS[@]}" "3" "three packages from newlines"
    assert_eq "${IMAGE_PATHS[api]}"      "bcgov/myapp/api"      "api path"
    assert_eq "${IMAGE_PATHS[frontend]}" "bcgov/myapp/frontend" "frontend path"
    assert_eq "${IMAGE_PATHS[db]}"       "bcgov/myapp/db"       "db path"
}

test_case_normalization() {
    map_packages "Frontend, QUICKSTART-Openshift" "BCGov/Quickstart-Openshift"
    assert_eq "${IMAGE_PATHS[Frontend]}" "bcgov/quickstart-openshift/frontend" \
        "image path is lowercased regardless of input case"
    assert_eq "${IMAGE_PATHS[QUICKSTART-Openshift]}" "bcgov/quickstart-openshift" \
        "repo-root match is case-insensitive"
}

test_empty_input_rejected_in_action() {
    # The action.sh should reject empty input; we can't run the whole action
    # here, but we can at least verify our helper yields zero packages.
    map_packages "" "bcgov/myapp"
    # Dereferencing an empty declared-but-unpopulated -A array under `set -u`
    # can trip; explicitly guard with ${var+x}.
    local count=0
    if [[ -v IMAGE_PATHS ]]; then count="${#IMAGE_PATHS[@]}"; fi
    assert_eq "$count" "0" "empty input yields no packages"
}

test_whitespace_only_entries_ignored() {
    map_packages "  ,frontend,   ,backend  ," "bcgov/myapp"
    assert_eq "${#IMAGE_PATHS[@]}" "2" "whitespace-only entries are skipped"
    assert_eq "${IMAGE_PATHS[frontend]}" "bcgov/myapp/frontend" "frontend retained"
    assert_eq "${IMAGE_PATHS[backend]}"  "bcgov/myapp/backend"  "backend retained"
}

test_space_separated_packages() {
    map_packages "frontend backend migrations" "bcgov/myapp"
    assert_eq "${#IMAGE_PATHS[@]}" "3" "space-separated: correct package count"
    assert_eq "${IMAGE_PATHS[frontend]}"   "bcgov/myapp/frontend"   "space-separated: frontend path"
    assert_eq "${IMAGE_PATHS[backend]}"    "bcgov/myapp/backend"    "space-separated: backend path"
    assert_eq "${IMAGE_PATHS[migrations]}" "bcgov/myapp/migrations" "space-separated: migrations path"
}

# -- Git plumbing sanity (runs in the checked-out repo) ----------------------

test_git_head_resolution() {
    local sha
    sha=$(git rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null || echo "")
    local ok="false"
    [[ "$sha" =~ ^[a-f0-9]{40}$ ]] && ok="true"
    assert_eq "$ok" "true" "HEAD resolves to a 40-char commit SHA"
}

test_pr_extraction() {
    local payload="abc1234|sha256:1234567890|2026-01-01T00:00:00Z|42|Fix something"
    local r_pr=""
    { IFS='|' read -r _ _ _ p_pr _; } <<< "$payload"
    if [[ -n "$p_pr" && "$p_pr" != "null" ]]; then
        r_pr="$p_pr"
    fi
    assert_eq "$r_pr" "42" "PR number extracted from payload"

    local empty_payload="abc1234|sha256:1234567890|2026-01-01T00:00:00Z||Fix something"
    r_pr=""
    { IFS='|' read -r _ _ _ p_pr _; } <<< "$empty_payload"
    if [[ -n "$p_pr" && "$p_pr" != "null" ]]; then
        r_pr="$p_pr"
    fi
    assert_eq "$r_pr" "" "Empty PR number handled cleanly"
}

echo "Running image-tracker unit tests..."
echo "Bash: $BASH_VERSION"
echo ""
test_single_package_nested
test_single_package_repo_root
test_multiple_packages_comma
test_multiple_packages_newline
test_case_normalization
test_empty_input_rejected_in_action
test_whitespace_only_entries_ignored
test_space_separated_packages
test_git_head_resolution
test_pr_extraction
echo ""
echo "Results: $passed passed, $failed failed"
[[ $failed -gt 0 ]] && exit 1
exit 0
