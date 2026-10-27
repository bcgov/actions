# Workflow Results

Consolidate upstream job results into a single merge gate or workflow rollup with a formatted summary table and error annotations.

Often consumed as the final required status check in GitHub Actions workflows across BCGov repositories (e.g. `quickstart-openshift`), with built-in failure alerts via [`workflow-notifier`](../workflow-notifier/) on merge, release and scheduled runs.

## Features

- ✅ **Consolidated Workflow Rollup**: Replaces fragile copy-pasted inline bash in `always()` rollup jobs.
- ✅ **Summary Table**: Emits a Markdown status table to `$GITHUB_STEP_SUMMARY` showing each job's result with intuitive status badges.
- ✅ **Error Annotations**: Emits `::error::` annotations on failure or cancellation for immediate triage in GitHub's check rollup without digging into log context.
- ✅ **Path-Filter Friendly**: Treats `skipped` jobs as passing by default, allowing workflows using [`diff-triggers`](../diff-triggers/) to merge smoothly.
- ✅ **Zero Silent Merges**: Correctly flags `failure`, `cancelled` (double _l_), and unexpected statuses.
- ✅ **Fail-Fast Safety**: Prevents hollow gates from passing if the `needs` context is empty or missing upstream job definitions.
- ✅ **Built-in Notify**: On failure, opens or comments on a [`workflow-notifier`](../workflow-notifier/) issue. On by default except for `pull_request` / `pull_request_target`.
- ✅ **Zero Dependencies**: Pure Node 24 standard library gate inside a thin composite wrapper.

## Permissions

Depends on whether notify fires for the event:

| `notify`                                | Permissions                                                                        |
| :-------------------------------------- | :--------------------------------------------------------------------------------- |
| off (PR events by default, or `false`)  | none (`permissions: {}`)                                                           |
| on (other events by default, or `true`) | `contents: read`, `issues: write` (+ `pull-requests: read` for merger attribution) |

## Usage

### Basic `PR Results` Merge Gate

```yaml
results:
  name: PR Results
  needs: [build, test, deploy]
  if: always()
  runs-on: ubuntu-24.04
  timeout-minutes: 1
  steps:
    - name: PR Results Check
      uses: bcgov/actions/workflow-results@vX.Y.Z # Replace with latest release tag
      with:
        needs: ${{ toJson(needs) }}
```

### `Analysis Results` (Security, Linters & Sonar)

```yaml
results:
  name: Analysis Results
  needs: [backend-tests, frontend-tests, trivy]
  if: always() && (! github.event.pull_request.draft)
  runs-on: ubuntu-24.04
  timeout-minutes: 1
  steps:
    - name: Analysis Results Check
      uses: bcgov/actions/workflow-results@vX.Y.Z
      with:
        needs: ${{ toJson(needs) }}
        title: 'Analysis Results'
```

### Merge, Release or Scheduled Workflows (notify on failure)

No extra steps: on non-PR events a failed gate checks out CODEOWNERS and notifies via [`workflow-notifier`](../workflow-notifier/).

```yaml
results:
  name: Nightly Results
  needs: [integration-tests, backup-verify, security-audit]
  if: always()
  runs-on: ubuntu-24.04
  permissions:
    contents: read
    issues: write
    pull-requests: read
  steps:
    - uses: bcgov/actions/workflow-results@vX.Y.Z
      with:
        needs: ${{ toJson(needs) }}
        title: 'Nightly Suite Results'
```

The standalone [`workflow-notifier`](../workflow-notifier/) remains for workflows without a results rollup (e.g. cert-expiry checks).

### Full Configuration Options

```yaml
- uses: bcgov/actions/workflow-results@vX.Y.Z
  with:
    # Required: JSON representation of upstream job results
    needs: ${{ toJson(needs) }}

    # Optional: Header title for the step summary table and log group
    # Default: "Workflow Results"
    title: 'Workflow Results'

    # Optional: notify on failure. Empty = notify unless pull_request/pull_request_target
    # Default: ""
    notify: ''

    # Optional: token for notifications. Default: github.token
    token: ${{ github.token }}
```

## Outputs

| Output   | Description                                                                          |
| :------- | :----------------------------------------------------------------------------------- |
| `passed` | Boolean string indicating if all jobs passed or were skipped (`'true'` or `'false'`) |
