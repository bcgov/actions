# Image targeting helpers for builder. Sourced by action.yml and tests.
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

# apply_revision_label LABELS SHA
# Prints labels with org.opencontainers.image.revision set to SHA (the commit
# we tagged and checked out). Drops any existing revision line so metadata-action
# cannot stamp GITHUB_SHA (the throwaway PR merge ref). Empty SHA: labels unchanged.
apply_revision_label() {
  local labels="$1"
  local sha="$2"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      org.opencontainers.image.revision=*) continue ;;
    esac
    printf '%s\n' "$line"
  done <<EOF
${labels}
EOF
  if [ -n "$sha" ]; then
    printf 'org.opencontainers.image.revision=%s\n' "$sha"
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

# is_external_repository INPUT_REPOSITORY GH_REPOSITORY
# True when building from a different repo than the workflow context.
is_external_repository() {
  [ "${1,,}" != "${2,,}" ]
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

BUILDER_FORK_DOCS_URL="${BUILDER_FORK_DOCS_URL:-https://github.com/bcgov/actions/blob/main/builder/README.md#fork-builds}"

# fork_visibility_message [DOCS_URL]
fork_visibility_message() {
  local docs_url="${1:-$BUILDER_FORK_DOCS_URL}"
  printf 'Images built from forks require that the fork set package visibility to public. See %s for details.' \
    "$docs_url"
}

# fork_pr_publish_message IMAGE_PATH SOURCE_SHA [DOCS_URL]
fork_pr_publish_message() {
  local image_path="$1"
  local source_sha="$2"
  local docs_url="${3:-$BUILDER_FORK_DOCS_URL}"
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

  printf '%s\n' "builder refuses pull_request_target from a fork. That event has write access to ghcr.io/${gh_repo} and this action checks out PR head, which would publish an untrusted image to the base registry. Use the same pull_request workflow instead; images publish on push to the fork. See ${BUILDER_FORK_DOCS_URL}"
}

# needs_qemu PLATFORMS RUNNER_ARCH
# Exits 0 (true) if any requested platform requires QEMU emulation on the runner.
# Exits 1 (false) if platforms is empty or all platforms match the runner architecture.
needs_qemu() {
  local platforms="$1"
  local runner_arch="${2,,}"

  local cleaned="${platforms//[[:space:],]/}"
  if [ -z "$cleaned" ]; then
    return 1
  fi

  local saved_shopts
  saved_shopts="$(set +o)"
  set -f

  local p
  local result=1
  for p in $(printf '%s' "$platforms" | tr ',\n\r\t' ' '); do
    p="${p,,}"
    [ -z "$p" ] && continue

    case "$runner_arch" in
      x64|amd64)
        case "$p" in
          linux/amd64|amd64) ;;
          *) result=0; break ;;
        esac
        ;;
      arm64|aarch64)
        case "$p" in
          linux/arm64|arm64|linux/arm64/*) ;;
          *) result=0; break ;;
        esac
        ;;
      arm)
        case "$p" in
          linux/arm|arm|linux/arm/*) ;;
          *) result=0; break ;;
        esac
        ;;
      x86|386|i386)
        case "$p" in
          linux/386|386|linux/i386) ;;
          *) result=0; break ;;
        esac
        ;;
      *)
        result=0
        break
        ;;
    esac
  done

  eval "$saved_shopts"
  return "$result"
}
