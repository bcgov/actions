# PR Results

Consolidate upstream job results into a single merge gate with a formatted summary table and error annotations.

Often consumed as the final required status check in GitHub Actions workflows across BCGov repositories (e.g. `quickstart-openshift`).

## Features

- ✅ **Consolidated Merge Gate**: Replaces fragile copy-pasted inline bash in `always()` rollup jobs.
- ✅ **Summary Table**: Emits a Markdown status table to `$GITHUB_STEP_SUMMARY` showing each job's result with intuitive status badges.
- ✅ **Error Annotations**: Emits `::error::` annotations on failure or cancellation for immediate triage in GitHub's check rollup without digging into log context.
- ✅ **Path-Filter Friendly**: Treats `skipped` jobs as passing by default, allowing workflows using [`diff-triggers`](../diff-triggers/) to merge smoothly.
- ✅ **Zero Silent Merges**: Correctly flags `failure`, `cancelled` (double _l_), `canceled` (single _l_), and unexpected statuses.
- ✅ **Fail-Fast Safety**: Prevents hollow gates from passing if the `needs` context is empty or missing upstream job definitions.
- ✅ **Zero Dependencies**: Pure Node 24 standard library execution (`runs: using: node24`).

## Permissions

No elevated permissions are required:

```yaml
permissions: {}
```

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
      uses: bcgov/actions/pr-results@vX.Y.Z # Replace with latest release tag
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
      uses: bcgov/actions/pr-results@vX.Y.Z
      with:
        needs: ${{ toJson(needs) }}
        title: 'Analysis Results'
```

### Full Configuration Options

```yaml
- uses: bcgov/actions/pr-results@vX.Y.Z
  with:
    # Required: JSON representation of upstream job results
    needs: ${{ toJson(needs) }}

    # Optional: Header title for the step summary table and log group
    # Default: "PR Results"
    title: 'PR Results'

    # Optional: Whether to write markdown table to $GITHUB_STEP_SUMMARY
    # Default: "true"
    summary: 'true'

    # Optional: Whether to emit ::error:: annotations on failures/cancellations
    # Default: "true"
    annotations: 'true'
```

## Outputs

| Output      | Description                                                                          |
| :---------- | :----------------------------------------------------------------------------------- |
| `passed`    | Boolean string indicating if all jobs passed or were skipped (`'true'` or `'false'`) |
| `failed`    | JSON array string containing keys of failed jobs (e.g. `'["test-backend"]'`)         |
| `cancelled` | JSON array string containing keys of cancelled jobs                                  |
| `skipped`   | JSON array string containing keys of skipped jobs                                    |
| `total`     | Total count of upstream jobs evaluated                                               |
