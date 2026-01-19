# report-failures

Creates GitHub Issues for deployment failures in test/prod zones with automatic assignment from CODEOWNERS file.

## Features

- Automatically creates GitHub Issues when deployments fail in test/prod environments
- Reads CODEOWNERS file to auto-assign issue maintainers
- Only runs on failure conditions (use with `if: failure()`)
- Skips for PR deployments (failures are visible in PR checks)
- Handles permission issues gracefully (mentions users if assignment fails)

## Usage

### Basic Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy
        run: ./deploy.sh

  report-failures:
    name: Failure Reporting
    if: failure() && (inputs.zone == 'test' || inputs.zone == 'prod')
    needs: deploy
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read
    steps:
      - name: Report Deployment Failure
        uses: bcgov/actions/report-failures@main
        with:
          zone: ${{ inputs.zone }}
```

### With Custom Templates

```yaml
- name: Report Deployment Failure
  uses: bcgov/actions/report-failures@main
  with:
    zone: prod
    title_template: "🚨 Production Deployment Failed - {zone}"
    body_template: |
      Deployment to **{zone}** has failed.
      
      [View workflow run]({workflow_url})
      
      Please investigate immediately.
```

### Accessing Outputs

```yaml
- name: Report Deployment Failure
  id: report
  uses: bcgov/actions/report-failures@main
  with:
    zone: test

- name: Use Issue Info
  run: |
    echo "Issue #${{ steps.report.outputs.issue_number }} created"
    echo "Issue URL: ${{ steps.report.outputs.issue_url }}"
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `zone` | Environment zone (test/prod) | Yes | - |
| `workflow_run_id` | Override workflow run ID (defaults to current run) | No | Current run ID |
| `title_template` | Custom issue title template. Use `{zone}` placeholder | No | `ci(deploy): deployment failed in {zone}` |
| `body_template` | Custom issue body template. Use `{zone}` and `{workflow_url}` placeholders | No | Default message with workflow link |
| `codeowners_path` | Override CODEOWNERS file path (auto-detected if not provided) | No | Auto-detected |

## Outputs

| Output | Description |
|-------|-------------|
| `issue_number` | Created issue number |
| `issue_url` | URL to created issue |

## CODEOWNERS Detection

The action automatically searches for CODEOWNERS files in the following locations (in order):
1. Repository root
2. `.github/` directory
3. `docs/` directory

The search is case-insensitive, so it will find files named `CODEOWNERS`, `codeowners`, `CodeOwners`, etc.

## Assignment Logic

- Extracts all usernames from CODEOWNERS file (ignores path patterns)
- Filters out team references (teams cannot be assigned to issues)
- Limits to 10 assignees (GitHub API limit)
- If assignment fails due to permissions, mentions users in issue body instead

## Permissions

This action requires the following permissions:

```yaml
permissions:
  issues: write  # To create issues
  contents: read # To read CODEOWNERS file
```

## Examples

### Full Deployment Workflow

```yaml
name: Deploy

on:
  workflow_dispatch:
    inputs:
      zone:
        description: 'Deployment zone'
        required: true
        type: choice
        options:
          - test
          - prod

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        run: ./deploy.sh

  report-failures:
    name: Failure Reporting
    if: failure() && (github.event.inputs.zone == 'test' || github.event.inputs.zone == 'prod')
    needs: deploy
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read
    steps:
      - name: Report Deployment Failure
        uses: bcgov/actions/report-failures@main
        with:
          zone: ${{ github.event.inputs.zone }}
```

## Notes

- This action should only run on failure conditions (use `if: failure()`)
- It's designed for test/prod deployments, not PR deployments
- The action will gracefully handle missing CODEOWNERS files
- Issue creation errors will fail the step (to surface deployment issues)

