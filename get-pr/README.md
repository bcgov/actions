# Get PR Number

Get PR number for merge queues, squash merges, and releases. PR numbers are easy to come by in PRs, but passing those same numbers to releases, merge queues and PR-backed merges can get tricky. This action makes that convenient.

## Features

- **PR Merge Queues**: Automatically extracts PR number from merge queue events
- **Merged PR Workflows**: Finds the PR that was just merged
- **Release Events**: Finds the most recently merged PR tied to the release
- **PRs Themselves**: Works in regular PR events for consistency

## Usage

```yaml
- id: vars
  uses: bcgov/actions/get-pr@v1

- name: Echo PR number
  run: echo "PR: ${{ steps.vars.outputs.pr }}"
```

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `token` | Specify token (GH or PAT), instead of inheriting one from the calling workflow | `${{ github.token }}` |
| `debug` | Enable debug logging | `'false'` |

## Outputs

| Name | Description |
|------|-------------|
| `pr` | Associated pull request number (empty if not found) |

## Examples

### Basic Usage

```yaml
- id: vars
  uses: bcgov/actions/get-pr@v1

- name: Use PR number
  run: echo "Building PR ${{ steps.vars.outputs.pr }}"
```

### Private Repositories

```yaml
- id: vars
  uses: bcgov/actions/get-pr@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

### Merge Queue

```yaml
on:
  merge_group:

jobs:
  get-pr:
    runs-on: ubuntu-latest
    steps:
      - id: vars
        uses: bcgov/actions/get-pr@v1
      - run: echo "Merge queue PR: ${{ steps.vars.outputs.pr }}"
```

### Release Event

```yaml
on:
  release:
    types: [published]

jobs:
  get-pr:
    runs-on: ubuntu-latest
    steps:
      - id: vars
        uses: bcgov/actions/get-pr@v1
      - run: echo "Release PR: ${{ steps.vars.outputs.pr }}"
```