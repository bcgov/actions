# Get PR Number - Merges and Queues

> [!WARNING]
> **Deprecated.** `get-pr` is kept only so `bcgov/action-get-pr` callers can switch to `bcgov/actions/get-pr` without other edits. It will be removed in `v2.0.0`. Use [image-tracker](../image-tracker/README.md#replacing-get-pr) instead: omit `packages` to resolve only the PR number. See [ADR 0002](../docs/adr/0002-restore-get-pr-until-v2.md).

PR numbers are easy to come by in PRs, but passing those same numbers to releases, merge queues and PR-backed merges can get tricky. This action makes that convenient in the following cases:
* PR merge queues
* Merged PR workflows
* Release events (finds the most recently merged PR)
* PRs themselves (just for consistency)

This process has been an integral part of PR-based workflows where images are promoted from development (PRs) to test/staging to production. It is also useful for release events where the most recent PR is tied to the release.

# Usage

The build will return a PR number as output.

```yaml
- id: vars
  uses: bcgov/actions/get-pr@vX.Y.Z # Replace with latest release tag

- name: Echo PR number
  run: |
    echo "PR: ${{ steps.vars.outputs.pr }}"
```

# Inputs

| Input | Default | Description |
|---|---|---|
| `token` | `github.token` | Authentication token. Set it only to use a PAT. |
| `github_token` | (none) | `bcgov/action-get-pr` name for `token`. When set, it is used instead of `token`. |
| `debug` | `false` | Log each lookup step. A run re-run with debug logging also turns it on. |

# Outputs

| Output | Description |
|---|---|
| `pr` | Associated pull request number |

# Switching from bcgov/action-get-pr

Change only the `uses:` line; `debug`, `github_token` and `outputs.pr` are unchanged.

```yaml
- id: vars
  uses: bcgov/actions/get-pr@vX.Y.Z # was bcgov/action-get-pr@v0.3.1

- name: Echo PR number
  run: |
    echo "PR: ${{ steps.vars.outputs.pr }}"
```

<!-- # Acknowledgements
This Action is provided courtesy of Forestry Digital Services, part of the Government of British Columbia. -->
