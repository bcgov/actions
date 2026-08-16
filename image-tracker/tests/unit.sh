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

# -- Step summary rendering tests -------------------------------------------

render_step_summary() {
    local target_str
    if [[ "$REVISION" == "$PIVOT_SHA"* || "$PIVOT_SHA" == "$REVISION"* ]]; then
        target_str="\`${PIVOT_SHA:0:7}\`"
    else
        target_str="\`${PIVOT_SHA:0:7}\` (${REVISION})"
    fi

    echo "### 📦 Image Tracker"
    echo ""
    echo "| Package | Target Commit | Resolved Commit | Search Depth | Image Reference / Digest |"
    echo "| :--- | :--- | :--- | :--- | :--- |"

    for pkg in "${PKG_ORDER[@]}"; do
        local payload="${IMAGES[$pkg]:-}"
        local path="${IMAGE_PATHS[$pkg]:-}"
        if [[ -n "$payload" ]]; then
            local sha digest created pr_num msg
            IFS='|' read -r sha digest created pr_num msg <<< "$payload"
            local ref="ghcr.io/${path}@${digest}"
            local resolved_str="\`${sha:0:7}\`"
            local depth=0
            for i in "${!CANDIDATES[@]}"; do
                if [[ "${CANDIDATES[$i]}" == "$sha"* || "$sha" == "${CANDIDATES[$i]}"* ]]; then
                    depth=$((i + 1))
                    break
                fi
            done
            local depth_str
            if [[ "$depth" -eq 1 ]]; then
                depth_str="1"
            elif [[ "$depth" -gt 1 ]]; then
                depth_str="${depth} (walked)"
            else
                depth_str="—"
            fi
            echo "| \`${pkg}\` | ${target_str} | ${resolved_str} | ${depth_str} | \`${ref}\` |"
        else
            echo "| \`${pkg}\` | ${target_str} | — | — | *Not resolved* |"
        fi
    done
    echo ""
}

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
test_render_step_summary_head_and_walked
test_render_step_summary_with_missing_and_sha_revision
echo ""
echo "Results: $passed passed, $failed failed"
[[ $failed -gt 0 ]] && exit 1
exit 0
