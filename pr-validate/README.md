# PR Validate

Validate Pull Request metadata and apply organizational guardrails to contributor pull requests.

## Features

- ✅ **Conventional Commits**: Enforces semantic pull request titles (e.g. `feat: ...`, `fix: ...`) per [conventionalcommits.org](https://www.conventionalcommits.org/) using `amannn/action-semantic-pull-request`.
- ✅ **Educational UX**: Provides explicit, custom GitHub annotations when title validation fails, instructing contributors exactly how to fix the issue without manually retrying CI.
- ✅ **Fork notice**: Emits a warning on fork pull requests with a link to fork CI configuration guidance. Validation continues (conventional commits, etc.).

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  pull-requests: read
```

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
```

### Fork pull requests

Fork PRs receive a workflow warning and continue validation. They use read-only tokens on the base repo; actions that need write access (e.g. `pr-description-add`) must no-op or be skipped separately. See the [fork builds guide](../builder-ghcr/README.md#fork-builds).
