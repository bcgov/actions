# PR Validate

Validate Pull Request metadata and apply organizational guardrails to contributor pull requests.

## Features

- ✅ **Conventional Commits**: Enforces semantic pull request titles (e.g. `feat: ...`, `fix: ...`) per [conventionalcommits.org](https://www.conventionalcommits.org/) using `amannn/action-semantic-pull-request`.
- ✅ **Educational UX**: Provides explicit, custom GitHub annotations when title validation fails, instructing contributors exactly how to fix the issue without manually retrying CI.
- ✅ **PR description**: Optional `add_markdown` appends text via [`pr-description-add`](../pr-description-add/).
- ✅ **Fork notice**: Emits a warning on fork pull requests with a link to fork CI configuration guidance. Validation continues (conventional commits, etc.).

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  pull-requests: read
```

If `add_markdown` is set, also grant `pull-requests: write`.

## Usage

```yaml
- name: Validate PR
  uses: bcgov/actions/pr-validate@vX.Y.Z # Replace with latest release tag
  # No inputs required — checks PR title and emits a fork notice when applicable.

- name: Validate PR (With Custom Inputs)
  uses: bcgov/actions/pr-validate@vX.Y.Z
  with:
    # Optional: Enforce Conventional Commits format on the PR title
    # Default: "true"
    conventional_commits: "true"

    # Optional: Append markdown to the PR body (skips when empty)
    add_markdown: |
      ---
      Deployments will be available below.

    # Optional: Authentication token (defaults to github.token; override with PAT if needed)
    token: ${{ secrets.GITHUB_TOKEN }}
```

### Fork pull requests

Fork PRs receive a workflow warning and continue validation. They use read-only tokens on the base repo; `pr-description-add` no-ops on forks. See the [fork pull requests guide](../README.md#fork-pull-requests).
