#!/usr/bin/env bash
# Fork PR guidance for pr-validate (sourced by action.yml and self-check).
ACTIONS_FORK_DOCS_URL="${ACTIONS_FORK_DOCS_URL:-https://github.com/bcgov/actions/blob/main/README.md#fork-pull-requests}"

fork_pr_warning() {
  printf 'Fork pull requests run with read-only tokens on the base repository; some steps may be skipped or fail. See %s for details.' \
    "$ACTIONS_FORK_DOCS_URL"
}
