# Get PR Number - Merges and Queues

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
  uses: bcgov/actions/get-pr@v1
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}

- name: Echo PR number
  run: echo "PR: ${{ steps.vars.outputs.pr }}"
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `github_token` | GitHub token | `${{ github.token }}` |
| `debug` | Enable debug logging | `false` |

## Outputs

| Name | Description |
|------|-------------|
| `pr` | Associated pull request number |
