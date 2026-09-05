# workflow-notifier

Find CODEOWNERS and triggering workflow/PR merge authors, notifying them via GitHub Issues on workflow/job failure.

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read       # Required to discover CODEOWNERS files in the repository
  issues: write        # Required to create issues and assign owners
  pull-requests: read  # Optional: required to resolve author from pull request metadata on merge commits
```

The action reads `CODEOWNERS` from the **job workspace**, not from the action bundle. A full `actions/checkout` is the usual approach; a sparse checkout of `.github/CODEOWNERS` is enough when you only need owner discovery.

## Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `token` | GitHub token | `${{ github.token }}` | No |
| `debug` | Enable debug logging | `"false"` | No |
| `title` | Issue title | | **Yes** |
| `body` | Issue body (pre-filled with workflow run URL if omitted) | | No |
| `labels` | Comma-separated list of labels to add to the issue | `"bug,failure"` | No |
| `assign` | Whether to assign owners to the issue | `"true"` | No |
| `notify_author` | Whether to notify the triggering author/merger on failure | `"true"` | No |
| `notify_codeowners` | Whether to notify repository CODEOWNERS on failure | `"true"` | No |
| `dry_run` | If true, logs the issue creation without actually creating it | `"false"` | No |

## Outputs

| Output | Description |
|---|---|
| `issue_number` | The created issue number (0 if dry run) |
| `assignees` | Comma-separated list of assigned owners |

## Usage

```yaml
- name: Notify on Failure
  if: failure()
  uses: bcgov/actions/workflow-notifier@vX.Y.Z
  with:
    title: "Production build failed"
    body: "Please check the logs for details."
```

## Local Debugging

You can test and debug the bash script locally by setting the inputs as environment variables and executing the script:

```bash
export INPUT_TOKEN="your_personal_access_token"
export INPUT_DEBUG="true"
export INPUT_TITLE="Local Test Failure"
export INPUT_BODY="Testing action script locally"
export INPUT_LABELS="bug,test"
export INPUT_ASSIGN="false"
export INPUT_DRY_RUN="true"

# Execute the shell script directly
./action.sh
```
