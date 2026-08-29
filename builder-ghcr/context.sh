# Image targeting helpers for builder-ghcr. Sourced by action.yml and tests.
# Not executed directly.

# image_path_for PACKAGE GITHUB_REPOSITORY REPO_NAME
# Prints owner/repo or owner/repo/package (lowercased).
image_path_for() {
  local package="${1,,}"
  local gh_repo="${2,,}"
  local repo_name="${3,,}"
  if [ "$package" = "$repo_name" ]; then
    printf '%s\n' "$gh_repo"
  else
    printf '%s/%s\n' "$gh_repo" "$package"
  fi
}

# source_sha HEAD_SHA GITHUB_SHA
# Prefer PR head (the commit deploy will pull), else the triggering commit.
source_sha() {
  local head_sha="$1"
  local github_sha="$2"
  if [ -n "$head_sha" ]; then
    printf '%s\n' "$head_sha"
  else
    printf '%s\n' "$github_sha"
  fi
}

# merge_sha_tag TAGS_MULTILINE SHA
# Prints tags with SHA appended if missing. Drops empty lines. Lowercases.
merge_sha_tag() {
  local tags="$1"
  local sha="${2,,}"
  local found=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    line="${line,,}"
    printf '%s\n' "$line"
    [ "$line" = "$sha" ] && found=1
  done <<EOF
${tags}
EOF
  if [ -n "$sha" ] && [ "$found" -eq 0 ]; then
    printf '%s\n' "$sha"
  fi
}

# is_fork_pr GH_REPOSITORY HEAD_REPO
# True when a pull_request originates from a different repository (fork).
is_fork_pr() {
  local gh_repo="${1,,}"
  local head_repo="${2,,}"
  [ -n "$head_repo" ] && [ "$head_repo" != "$gh_repo" ]
}

# publish_repository EVENT_NAME GH_REPOSITORY HEAD_REPO
# GHCR owner/repo (or fork head repo on fork pull_request) where images live.
publish_repository() {
  local event_name="$1"
  local gh_repo="${2,,}"
  local head_repo="${3,,}"

  if [ "$event_name" = "pull_request" ] && is_fork_pr "$gh_repo" "$head_repo"; then
    printf '%s\n' "$head_repo"
    return
  fi
  printf '%s\n' "$gh_repo"
}

# can_push_packages EVENT_NAME GH_REPOSITORY HEAD_REPO
# Exits 0 when this run may push/retag to GHCR; 1 on read-only fork pull_request.
can_push_packages() {
  local event_name="$1"
  local gh_repo="${2,,}"
  local head_repo="${3,,}"

  if [ "$event_name" = "pull_request" ] && is_fork_pr "$gh_repo" "$head_repo"; then
    return 1
  fi
  return 0
}

BUILDER_GHCR_FORK_DOCS_URL="${BUILDER_GHCR_FORK_DOCS_URL:-https://github.com/bcgov/actions/blob/main/builder-ghcr/README.md#fork-builds}"

# fork_visibility_message [DOCS_URL]
fork_visibility_message() {
  local docs_url="${1:-$BUILDER_GHCR_FORK_DOCS_URL}"
  printf 'Images built from forks require that the fork set package visibility to public. See %s for details.' \
    "$docs_url"
}

# fork_pr_publish_message IMAGE_PATH SOURCE_SHA [DOCS_URL]
fork_pr_publish_message() {
  local image_path="$1"
  local source_sha="$2"
  local docs_url="${3:-$BUILDER_GHCR_FORK_DOCS_URL}"
  printf 'Fork pull_request cannot push to GHCR (read-only token). Build validates only; images publish on push to your fork at ghcr.io/%s:%s. See %s for details.' \
    "$image_path" "$source_sha" "$docs_url"
}

# is_fork_repository REPO_IS_FORK
# REPO_IS_FORK is the string "true" or "false" from github.event.repository.fork.
is_fork_repository() {
  [ "${1,,}" = "true" ]
}

# refuse_reason EVENT_NAME GITHUB_REPOSITORY HEAD_REPO
# Prints a reason to refuse, or nothing if the action may proceed.
refuse_reason() {
  local event_name="$1"
  local gh_repo="${2,,}"
  local head_repo="${3,,}"

  if [ "$event_name" != "pull_request_target" ]; then
    return 0
  fi

  if ! is_fork_pr "$gh_repo" "$head_repo"; then
    return 0
  fi

  printf '%s\n' "builder-ghcr refuses pull_request_target from a fork. That event has write access to ghcr.io/${gh_repo} and this action checkouts PR head, which would publish an untrusted image to the base registry. Use the same pull_request workflow instead; images publish on push to the fork. See ${BUILDER_GHCR_FORK_DOCS_URL}"
}
