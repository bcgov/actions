# Scan URL

Scan a running site's URL. Today this is security scanning with [ZAP](https://www.zaproxy.org/) and [Nuclei](https://github.com/projectdiscovery/nuclei); other scan types may be added later. Each scanner runs as its own step; results are not merged. One URL per run.

- **ZAP**: [`zaproxy/action-full-scan`](https://github.com/zaproxy/action-full-scan) runs a full (active) scan with `allow_issue_writing: false` and uploads its reports as the `zap_scan-<slug>` artifact. When `tests/.zap/rules.tsv` exists in the caller's workspace, it is passed as the rules file. The JSON report is converted to SARIF (`zap-results.sarif`) and uploaded under category `zap-<slug>`.
- **Nuclei**: [`projectdiscovery/nuclei-action`](https://github.com/projectdiscovery/nuclei-action) v3 installs Nuclei, then the action runs `nuclei -u <url> -jsonl-export nuclei-results.jsonl -sarif-export nuclei-results.sarif -rl <nuclei_rate_limit> -c <nuclei_concurrency> -timeout <nuclei_timeout>` and keeps its output in `nuclei.log`. SARIF is uploaded under category `nuclei-<slug>`. Nuclei writes SARIF only when it has findings, so after a clean scan the action uploads an empty run to close stale alerts.

`<slug>` is the URL without its scheme, with each run of non-alphanumeric characters replaced by `-` (e.g. `https://app.example.gov.bc.ca` → `app-example-gov-bc-ca`).

Reports stay in the job workspace for later steps (e.g. a caller report script).

## Failure policy

- Findings never fail the action.
- The action fails before any scan runs when `url` is not `http(s)://host[:port][/path]` (including empty), when `url` returns no HTTP response within 20 seconds (DNS failure, refused connection or timeout; any status code passes), when `zap` or `nuclei` is not exactly `'true'` or `'false'`, when both are `'false'`, or when a `nuclei_*` tuning input is not a whole number from 1 to 9999.
- The action fails when an enabled scanner's step fails or its report is missing (`report_json.json` for ZAP, `nuclei-results.jsonl` for Nuclei). A broken scan must not look like a clean one. ZAP SARIF still uploads for any report that exists; Nuclei SARIF uploads only when the Nuclei Scan step succeeded.
- The action fails when Nuclei skips the scanned host and port as unresponsive (`Skipped <host>:<port> from target list as found unresponsive permanently` or `... unresponsive N times`). Nuclei drops the target after connection timeouts, skips its remaining templates and still exits 0, so the scan is incomplete. The Nuclei Scan step fails, and its SARIF is not uploaded, because a partial scan would close alerts for templates that never ran. A skip on another host or port (a template probing e.g. `:8443` or a third-party site) only warns. If it happens, lower `nuclei_rate_limit` or `nuclei_concurrency`, or raise `nuclei_timeout`.

## Permissions

To run this action, the calling workflow job must have the following minimum permissions:

```yaml
permissions:
  contents: read          # Required to read tests/.zap/rules.tsv from the checkout
  security-events: write  # Required to upload SARIF to the Security tab
```

## Inputs

| Input | Description | Default | Required |
|---|---|---|---|
| `url` | URL to scan. Preflight fails if it gets no HTTP response (any status passes) | | **Yes** |
| `zap` | What to scan: run the ZAP full scan (`'true'` or `'false'`) | `'true'` | No |
| `nuclei` | What to scan: run the Nuclei scan (`'true'` or `'false'`) | `'true'` | No |
| `nuclei_rate_limit` | Nuclei maximum requests per second (`-rl`) | `'25'` | No |
| `nuclei_concurrency` | Nuclei templates run in parallel (`-c`) | `'5'` | No |
| `nuclei_timeout` | Nuclei seconds to wait for a connection or response (`-timeout`) | `'30'` | No |

`zap` and `nuclei` are "what to scan" toggles. Each gates its scanner's scan, SARIF conversion and upload. Any other value fails the action, and setting both to `'false'` fails it too, so a run never passes without scanning. Future scanners (e.g. accessibility) will get their own toggle, on by default.

The `nuclei_*` defaults are lower than Nuclei's own (150 requests per second, 25 templates, 10 seconds). At Nuclei's defaults, OpenShift TEST routes timed out within the first minute or two of a scan and Nuclei skipped the rest. Lower load makes that later or rarer, but a target that stops answering mid-scan still fails the action.

## Outputs

| Output | Description |
|---|---|
| `zap_json` | ZAP JSON report path, relative to the workspace (`report_json.json`) |
| `nuclei_jsonl` | Nuclei JSONL findings path, relative to the workspace (`nuclei-results.jsonl`) |

## Usage

Only scan URLs you own. A ZAP full scan sends attack payloads.

```yaml
jobs:
  scan-url:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v7 # Optional: needed only for tests/.zap/rules.tsv
      - uses: bcgov/actions/scan-url@vX.Y.Z # Replace with latest release tag
        with:
          url: https://my-app-test.apps.silver.devops.gov.bc.ca
```

### Several URLs

Use a matrix, one job per URL. SARIF categories and the ZAP artifact include the URL slug, so results for each URL stay separate.

```yaml
jobs:
  scan-url:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      security-events: write
    strategy:
      fail-fast: false
      matrix:
        url: [https://app.example.gov.bc.ca, https://api.example.gov.bc.ca]
    steps:
      - uses: actions/checkout@v7
      - uses: bcgov/actions/scan-url@vX.Y.Z # Replace with latest release tag
        with:
          url: ${{ matrix.url }}
```
