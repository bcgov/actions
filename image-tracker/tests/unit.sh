#!/usr/bin/env bash
# Unit tests for image-tracker's pure logic (no network).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the actual action script to test real implementation functions directly
source "${SCRIPT_DIR}/../action.sh"

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
    map_packages "" "bcgov/myapp"
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
    local p_pr=""
    { IFS='|' read -r _ _ _ p_pr _; } <<< "$payload"
    if [[ -n "$p_pr" && "$p_pr" != "null" ]]; then
        r_pr="$p_pr"
    fi
    assert_eq "$r_pr" "42" "PR number extracted from payload"

    local empty_payload="abc1234|sha256:1234567890|2026-01-01T00:00:00Z||Fix something"
    r_pr=""
    p_pr=""
    { IFS='|' read -r _ _ _ p_pr _; } <<< "$empty_payload"
    if [[ -n "$p_pr" && "$p_pr" != "null" ]]; then
        r_pr="$p_pr"
    fi
    assert_eq "$r_pr" "" "Empty PR number handled cleanly"
}

# -- Candidate matching tests -----------------------------------------------

test_matches_candidate_pr_tag_isolation() {
    local CANDIDATES=(
        "1111111111111111111111111111111111111111"
        "2222222222222222222222222222222222222222"
    )
    unset PR_MAP PR_NUM_MAP
    declare -A PR_MAP=()
    declare -A PR_NUM_MAP=(
        ["2222222222222222222222222222222222222222"]="99"
    )

    local match_cand2
    match_cand2=$(matches_candidate "" "pr-99" && echo "true" || echo "false")
    assert_eq "$match_cand2" "true" "matches_candidate succeeds for registered PR tag"

    local match_unregistered
    match_unregistered=$(matches_candidate "" "pr-100" && echo "true" || echo "false")
    assert_eq "$match_unregistered" "false" "matches_candidate rejects unregistered PR tag"
}

# -- Step summary rendering tests -------------------------------------------

test_render_step_summary_head_and_walked() {
    local PIVOT_SHA="a1b2c3d4e5f67890123456789012345678901234"
    local REVISION="HEAD"
    local CANDIDATES=(
        "a1b2c3d4e5f67890123456789012345678901234"
        "b2c3d4e5f67890123456789012345678901234a1"
        "e4f5g6h789012345678901234567890123456789"
    )
    local PKG_ORDER=("backend" "frontend")
    unset IMAGE_PATHS IMAGES
    declare -A IMAGE_PATHS=(
        ["backend"]="bcgov/quickstart-openshift/backend"
        ["frontend"]="bcgov/quickstart-openshift/frontend"
    )
    declare -A IMAGES=(
        ["backend"]="a1b2c3d4e5f67890123456789012345678901234|sha256:7f83b1...|2026-01-01T00:00:00Z|10|Backend commit"
        ["frontend"]="e4f5g6h789012345678901234567890123456789|sha256:39ac21...|2026-01-01T00:00:00Z|11|Frontend commit"
    )

    local output
    output=$(render_step_summary)

    local expected=$'### 📦 Image Tracker\n\n| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |\n| :--- | :--- | :--- | :--- | :--- |\n| `backend` | `a1b2c3d` (HEAD) | `a1b2c3d` | 1 | `ghcr.io/bcgov/quickstart-openshift/backend@sha256:7f83b1...` |\n| `frontend` | `a1b2c3d` (HEAD) | `e4f5g6h` | 3 (walked) | `ghcr.io/bcgov/quickstart-openshift/frontend@sha256:39ac21...` |'

    assert_eq "$output" "$expected" "step summary matches proposed provenance audit table format"
}

test_render_step_summary_with_missing_and_sha_revision() {
    local PIVOT_SHA="a1b2c3d4e5f67890123456789012345678901234"
    local REVISION="a1b2c3d"
    local CANDIDATES=(
        "a1b2c3d4e5f67890123456789012345678901234"
    )
    local PKG_ORDER=("api" "db")
    unset IMAGE_PATHS IMAGES
    declare -A IMAGE_PATHS=(
        ["api"]="bcgov/myapp/api"
        ["db"]="bcgov/myapp/db"
    )
    declare -A IMAGES=(
        ["api"]="a1b2c3d4e5f67890123456789012345678901234|sha256:111111|2026-01-01T00:00:00Z||Api commit"
    )

    local output
    output=$(render_step_summary)

    local expected=$'### 📦 Image Tracker\n\n| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |\n| :--- | :--- | :--- | :--- | :--- |\n| `api` | `a1b2c3d` | `a1b2c3d` | 1 | `ghcr.io/bcgov/myapp/api@sha256:111111` |\n| `db` | `a1b2c3d` | — | — | *Not resolved* |'

    assert_eq "$output" "$expected" "step summary handles sha revision and missing packages"
}

test_render_step_summary_escapes_pipes() {
    local PIVOT_SHA="a1b2c3d4e5f67890123456789012345678901234"
    local REVISION="feature|branch"
    local CANDIDATES=(
        "a1b2c3d4e5f67890123456789012345678901234"
    )
    local PKG_ORDER=("app|service")
    unset IMAGE_PATHS IMAGES
    declare -A IMAGE_PATHS=(
        ["app|service"]="bcgov/myapp/app_service"
    )
    declare -A IMAGES=(
        ["app|service"]="a1b2c3d4e5f67890123456789012345678901234|sha256:222222|2026-01-01T00:00:00Z||Pipe commit"
    )

    local output
    output=$(render_step_summary)

    local expected=$'### 📦 Image Tracker\n\n| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |\n| :--- | :--- | :--- | :--- | :--- |\n| `app\|service` | `a1b2c3d` (feature\|branch) | `a1b2c3d` | 1 | `ghcr.io/bcgov/myapp/app_service@sha256:222222` |'

    assert_eq "$output" "$expected" "step summary escapes pipes in revision and package names"
}

test_parse_auth_header_ghcr() {
    local parsed
    parsed=$(parse_auth_header 'www-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:user/image:pull"')
    assert_eq "$parsed" "https://ghcr.io/token|ghcr.io" "parse auth header for GHCR"
}

test_parse_auth_header_docker_hub() {
    local parsed
    parsed=$(parse_auth_header 'WWW-Authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io"')
    assert_eq "$parsed" "https://auth.docker.io/token|registry.docker.io" "parse auth header for Docker Hub"
}

test_parse_auth_header_quay() {
    local parsed
    parsed=$(parse_auth_header 'Www-Authenticate: Bearer realm="https://quay.io/v2/auth",service="quay.io"')
    assert_eq "$parsed" "https://quay.io/v2/auth|quay.io" "parse auth header for Quay"
}

test_parse_auth_header_artifactory() {
    local parsed
    parsed=$(parse_auth_header 'www-authenticate: Bearer realm="https://artifactory.corp/v2/token"')
    assert_eq "$parsed" "https://artifactory.corp/v2/token|" "parse auth header without service"
}

test_parse_auth_header_unquoted_and_case() {
    local parsed
    parsed=$(parse_auth_header 'WWW-AUTHENTICATE: Bearer REALM=https://example.com/token,SERVICE=example.com')
    assert_eq "$parsed" "https://example.com/token|example.com" "parse unquoted auth header with upper case keys"
}

test_parse_auth_header_no_realm() {
    local parsed
    parsed=$(parse_auth_header 'www-authenticate: Basic realm="foo"')
    assert_eq "$parsed" "foo|" "parse auth header basic realm"
}

test_render_step_summary_custom_registry() {
    local REGISTRY="registry-1.docker.io"
    local PIVOT_SHA="a1b2c3d4e5f67890123456789012345678901234"
    local REVISION="HEAD"
    local CANDIDATES=(
        "a1b2c3d4e5f67890123456789012345678901234"
    )
    local PKG_ORDER=("backend")
    unset IMAGE_PATHS IMAGES
    declare -A IMAGE_PATHS=(
        ["backend"]="bcgov/quickstart-openshift/backend"
    )
    declare -A IMAGES=(
        ["backend"]="a1b2c3d4e5f67890123456789012345678901234|sha256:7f83b1...|2026-01-01T00:00:00Z|10|Backend commit"
    )

    local output
    output=$(render_step_summary)

    local expected=$'### 📦 Image Tracker\n\n| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |\n| :--- | :--- | :--- | :--- | :--- |\n| `backend` | `a1b2c3d` (HEAD) | `a1b2c3d` | 1 | `registry-1.docker.io/bcgov/quickstart-openshift/backend@sha256:7f83b1...` |'

    assert_eq "$output" "$expected" "step summary uses custom registry host in image reference"
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
test_matches_candidate_pr_tag_isolation
test_parse_auth_header_ghcr
test_parse_auth_header_docker_hub
test_parse_auth_header_quay
test_parse_auth_header_artifactory
test_parse_auth_header_unquoted_and_case
test_parse_auth_header_no_realm
test_render_step_summary_head_and_walked
test_render_step_summary_with_missing_and_sha_revision
test_render_step_summary_escapes_pipes
test_render_step_summary_custom_registry
echo ""
echo "Results: $passed passed, $failed failed"
[[ $failed -gt 0 ]] && exit 1
exit 0
