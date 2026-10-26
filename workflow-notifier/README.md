# workflow-notifier

Find CODEOWNERS and triggering workflow/PR merge authors, notifying them via GitHub Issues on workflow/job failure.

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  actions: read        # Optional: lets scheduled runs check whether the previous scheduled run succeeded
  contents: read       # Required to discover CODEOWNERS files in the repository
  issues: write        # Required to create issues, comment on an open match, and assign owners
  pull-requests: read  # Optional: required to resolve author from pull request metadata on merge commits
```

On `schedule` events, when no matching issue is already open, the action checks the most recent completed scheduled run of the same workflow and skips creating an issue if that run succeeded (suppressing one-off network or runner-IP blips while still alerting on consecutive scheduled failures).

The action reads `CODEOWNERS` from the **job workspace**, not from the action bundle. A full `actions/checkout` is the usual approach; a sparse checkout of `.github/CODEOWNERS` is enough when you only need owner discovery.

## Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `token` | GitHub token | `${{ github.token }}` | No |
| `title` | Issue title. An open issue with this exact title gets a comment for each later run. A closed issue is not reused. | `"fix: failure in ${{ github.workflow }}"` | No |
| `body` | Issue body (pre-filled with workflow run URL if omitted) | | No |
| `notify_author` | Whether to notify the triggering author/merger on failure | `"true"` | No |
| `notify_codeowners` | When to notify repository CODEOWNERS on failure: `always`, `fallback` or `never`. By default (`fallback`), CODEOWNERS are only alerted if no human author/operator was resolved (e.g. scheduled cron runs). `always` always includes CODEOWNERS; `never` never does. | `"fallback"` | No |
| `dry_run` | If true, logs the issue create or comment without calling it | `"false"` | No |

Everyone `notify_author` and `notify_codeowners` select is assigned on create (up to 10); set `notify_author: false` and `notify_codeowners: never` to assign nobody. The action has no outputs.

## Usage

```yaml
- name: Notify on Failure
  if: failure()
  uses: bcgov/actions/workflow-notifier@vX.Y.Z
```

## Local Debugging

You can test and debug the bash script locally by setting the inputs as environment variables and executing the script:

```bash
export INPUT_TOKEN="your_personal_access_token"
export RUNNER_DEBUG="1"
export INPUT_TITLE="Local Test Failure"
export INPUT_BODY="Testing action script locally"
export INPUT_DRY_RUN="true"
export GITHUB_REPOSITORY="owner/repo"
export GITHUB_RUN_ID="0"

# Execute the shell script directly
./action.sh
```
