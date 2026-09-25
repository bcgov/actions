# DAST

Run [ZAP](https://www.zaproxy.org/) and [Nuclei](https://github.com/projectdiscovery/nuclei) against one URL. Each scanner runs as its own step; results are not merged.

- **ZAP**: [`zaproxy/action-full-scan`](https://github.com/zaproxy/action-full-scan) runs a full (active) scan, opens or updates a GitHub issue with alerts, and uploads its reports as the `zap_scan` artifact. When `tests/.zap/rules.tsv` exists in the caller's workspace, it is passed as the rules file. The JSON report is converted to SARIF (`zap-results.sarif`) and uploaded under category `zap`.
- **Nuclei**: [`projectdiscovery/nuclei-action`](https://github.com/projectdiscovery/nuclei-action) v3 runs with `-u <target> -jsonl-export nuclei-results.jsonl -sarif-export nuclei-results.sarif`. Nuclei writes SARIF only when it has findings; the action uploads it under category `nuclei` when present.

Reports stay in the job workspace for later steps (e.g. a caller report script).

## Failure policy

- Findings never fail the action.
- The action fails when `target` is empty or not an `http(s)://` URL, before any scan runs.
- The action fails when a scanner step fails or its report is missing (`report_json.json` for ZAP, `nuclei-results.jsonl` for Nuclei). A broken scan must not look like a clean one. SARIF uploads still run for any report that exists.

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read          # Required to read tests/.zap/rules.tsv from the checkout
  issues: write           # Required for ZAP to open or update its findings issue
  security-events: write  # Required to upload SARIF to the Security tab
```

## Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `target` | URL to scan with both ZAP and Nuclei | `https://<repo>-test.apps.silver.devops.gov.bc.ca` | No |

## Outputs

| Output | Description |
|---|---|
| `zap_json` | ZAP JSON report path, relative to the workspace (`report_json.json`) |
| `nuclei_jsonl` | Nuclei JSONL findings path, relative to the workspace (`nuclei-results.jsonl`) |

## Usage

Only scan targets you own. A ZAP full scan sends attack payloads.

```yaml
jobs:
  dast:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: write
      security-events: write
    steps:
      - uses: actions/checkout@v7 # Optional: needed only for tests/.zap/rules.tsv
      - uses: bcgov/actions/dast@vX.Y.Z # Replace with latest release tag
        with:
          target: https://my-app-test.apps.silver.devops.gov.bc.ca # Optional
```
