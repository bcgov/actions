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
- ✅ **Annotation Check**: Fails the gate when a job in the run concluded success but logged an error (`::error::`, `##[error]`) or GitHub's `Unexpected input(s)` warning. See [Annotation check](#annotation-check).
- ✅ **Built-in Notify**: On failure, opens or comments on a [`workflow-notifier`](../workflow-notifier/) issue. On by default except for `pull_request` / `pull_request_target`, and skips runs whose only non-passing jobs are `cancelled`.
- ✅ **Zero Dependencies**: Pure Node 24 standard library gate inside a thin composite wrapper.

## Permissions

Depends on whether notify fires for the event, plus two read permissions for the [annotation check](#annotation-check):

| Feature                                        | Permissions                                                                        |
| :--------------------------------------------- | :--------------------------------------------------------------------------------- |
| notify off (PR events by default, or `false`)  | none (`permissions: {}`)                                                           |
| notify on (other events by default, or `true`) | `contents: read`, `issues: write` (+ `pull-requests: read` for merger attribution) |
| annotation check (`check_annotations`, on)     | `actions: read`, `checks: read` (private and internal repos)                       |

Public repositories can read their own jobs and annotations without these, so the check runs even under `permissions: {}`. Private and internal repositories need them; without them the check logs a warning and is skipped, and the gate result is unchanged.

## Annotation check

A job can conclude `success` and still hide a problem: an action given an input it doesn't declare only gets a warning (`Unexpected input(s) 'x', valid inputs are [...]`), and a step can log `::error::` and exit 0. [`input-enforcer`](../input-enforcer/) only covers `bcgov/actions`, and actionlint lags new action majors, so these slip through.

The gate lists this run's latest jobs, reads the annotations of every completed job that concluded `success`, and fails when it finds:

- an error annotation (`::error::`, `##[error]`, including `Process completed with exit code N` from a `continue-on-error` step), or
- a warning containing `Unexpected input(s)`.

Other warnings and notices are ignored. Jobs still running, including the results job, are not read. GitHub attaches a job's annotations a few seconds after it completes, so the check first waits until 20 seconds after the latest of those jobs completed (at most 20 seconds). Every job in the run counts, not only those in `needs`. Findings are listed as error annotations and in the step summary, and on non-PR events they notify like any other gate failure.

Grant the results job the read permissions (needed for private and internal repositories):

```yaml
results:
  name: PR Results
  needs: [build, test, deploy]
  if: always()
  runs-on: ubuntu-24.04
  permissions:
    actions: read
    checks: read
  steps:
    - uses: bcgov/actions/workflow-results@vX.Y.Z
      with:
        needs: ${{ toJson(needs) }}
```

Set `check_annotations: false` for workflows whose jobs log errors on purpose and still pass.

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

No extra steps: on non-PR events a failed gate checks out CODEOWNERS and notifies via [`workflow-notifier`](../workflow-notifier/). Notify uses `notify_codeowners: fallback`, so a missing or empty CODEOWNERS file fails that step with `No names returned from codeowners` only when no author or merger was found.

```yaml
results:
  name: Nightly Results
  needs: [integration-tests, backup-verify, security-audit]
  if: always()
  runs-on: ubuntu-24.04
  permissions:
    actions: read
    checks: read
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

    # Optional: fail on errors or 'Unexpected input(s)' warnings in jobs that concluded success
    # Private and internal repos need actions: read and checks: read; skipped with a warning without them
    # Default: "true"
    check_annotations: 'true'

    # Optional: token for the annotation check and notifications. Default: github.token
    token: ${{ github.token }}
```

## Outputs

| Output        | Description                                                                          |
| :------------ | :----------------------------------------------------------------------------------- |
| `passed` | `'true'` only when all upstream jobs passed or were skipped and the [annotation check](#annotation-check) didn't fail; `'false'` otherwise, including when a job that concluded success has an error or `Unexpected input(s)` annotation |
| `annotations` | JSON array of findings from the [annotation check](#annotation-check) (`job`, `level`, `message`, `path`, `line`); `[]` when none, empty when the check is off or skipped |
