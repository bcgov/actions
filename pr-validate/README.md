# PR Validate

Validate Pull Request metadata and apply organizational guardrails to contributor pull requests.

## Features

- ✅ **Conventional Commits**: Enforces semantic pull request titles (e.g. `feat: ...`, `fix: ...`) per [conventionalcommits.org](https://www.conventionalcommits.org/) using `amannn/action-semantic-pull-request`.
- ✅ **Educational UX**: Provides explicit, custom GitHub annotations when title validation fails, instructing contributors exactly how to fix the issue without manually retrying CI.
- ✅ **Fork Blocking**: (Configurable) Immediately rejects pull requests opened from forks with educational instructions on how to use internal branches instead, securing CI environments against token exfiltration vulnerabilities.

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
  with:
    # Required: GitHub token to read PR metadata
    github_token: ${{ secrets.GITHUB_TOKEN }}

    # Optional: Enforce Conventional Commits format on the PR title
    # Default: "true"
    conventional_commits: "true"

    # Optional: Reject PRs originating from forks
    # Default: "true"
    reject_forks: "true"
```
