# workflow-notifier

Find CODEOWNERS and triggering workflow/PR merge authors, notifying them via GitHub Issues on workflow/job failure.

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read       # Required to discover CODEOWNERS files in the repository
  issues: write        # Required to create issues, comment on an open match, and assign owners
  pull-requests: read  # Optional: required to resolve author from pull request metadata on merge commits
```

The action reads `CODEOWNERS` from the **job workspace**, not from the action bundle. A full `actions/checkout` is the usual approach; a sparse checkout of `.github/CODEOWNERS` is enough when you only need owner discovery.

## Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `token` | GitHub token | `${{ github.token }}` | No |
| `title` | Issue title. An open issue with this exact title gets a comment for each later run. A closed issue is not reused. | `"fix: failure in ${{ github.workflow }}"` | No |
| `body` | Issue body (pre-filled with workflow run URL if omitted) | | No |
| `notify_author` | Whether to notify the triggering author/merger on failure | `"true"` | No |
| `notify_codeowners` | When to notify repository CODEOWNERS on failure: `always`, `fallback` or `never`. By default (`fallback`), CODEOWNERS are only alerted if no human author/operator was resolved (e.g. scheduled cron runs). `always` always includes CODEOWNERS; `never` never does. | `"fallback"` | No |
| `codeowners_match` | Which CODEOWNERS rules pick owners: `all`, `changed` or `workflow` (see [CODEOWNERS matching](#codeowners-matching)). | `"all"` | No |
| `dry_run` | If true, logs the issue create or comment without calling it | `"false"` | No |

Everyone `notify_author` and `notify_codeowners` select is assigned on create (up to 10); set `notify_author: false` and `notify_codeowners: never` to assign nobody. The action has no outputs.

## CODEOWNERS matching

The action reads the first CODEOWNERS file it finds, in GitHub's order: `.github/CODEOWNERS`, `CODEOWNERS`, `docs/CODEOWNERS`. `#` starts a comment anywhere on a line. Patterns follow GitHub's gitignore-style rules (`*`, `**`, `?`, trailing `/`, last match wins, a rule with no owners unsets ownership); `!` negation and `[ ]` ranges are not supported by GitHub CODEOWNERS and are matched literally.

| `codeowners_match` | Owners picked |
|---|---|
| `all` (default) | Every `@user` in the file, ignoring paths. |
| `changed` | For each file changed by the run's pull request (the event's PR, or the PR merged as `GITHUB_SHA` on push), the owners of the last matching rule, as GitHub does. With no PR (e.g. `schedule`, `workflow_dispatch`), falls back to `workflow`. Needs `pull-requests: read`. |
| `workflow` | Owners of the last rule matching the failing workflow file (e.g. `.github/workflows/merge.yml`). |

Team owners (`@org/team`) cannot be issue assignees, so they are skipped and logged; no team member or org is assigned in their place. Email owners are ignored. The log and job summary show the CODEOWNERS file, the mode, the users selected and any team or email owners skipped.

```yaml
- name: Notify on Failure
  if: failure()
  uses: bcgov/actions/workflow-notifier@vX.Y.Z
  with:
    notify_codeowners: always
    codeowners_match: changed
```

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
