#!/usr/bin/env bash
# Fork PR guidance for pr-validate (sourced by action.yml and self-check).
PR_VALIDATE_FORK_DOCS_URL="${PR_VALIDATE_FORK_DOCS_URL:-https://github.com/bcgov/actions/blob/main/builder-ghcr/README.md#fork-builds}"

fork_pr_warning() {
  printf 'Fork pull requests use read-only tokens and different configuration. See %s for details.' \
    "$PR_VALIDATE_FORK_DOCS_URL"
}
