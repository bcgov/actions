#!/usr/bin/env bash
# Prepare Nuclei SARIF after a successful scan:
# - When Nuclei produced SARIF, mark false executionSuccessful flags true
#   (nuclei <= v3.11.1 omits ExecutionSuccessful on its SARIF invocation).
# - When Nuclei produced only JSONL (clean scan), emit an empty SARIF run
#   so Code Scanning closes stale alerts.

set -euo pipefail

if [[ -f nuclei-results.sarif ]]; then
  tmp="$(mktemp nuclei-results.sarif.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  jq '(.runs[]?.invocations[]? | select(.executionSuccessful == false) | .executionSuccessful) = true' \
    nuclei-results.sarif > "$tmp"
  mv "$tmp" nuclei-results.sarif
elif [[ -f nuclei-results.jsonl ]]; then
  echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Nuclei"}},"results":[]}]}' > nuclei-results.sarif
fi
