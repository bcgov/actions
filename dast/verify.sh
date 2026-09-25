#!/usr/bin/env bash
# Findings never fail the action; a failed scanner step or missing report does.
# Env: ZAP_OUTCOME, NUCLEI_OUTCOME (step outcomes). Reads reports from the cwd.

set -euo pipefail

rc=0
check() {
  local name="$1" outcome="$2" report="$3"
  if [[ "$outcome" != success || ! -f "$report" ]]; then
    echo "::error::${name} did not complete: step ${outcome}, ${report} $([[ -f "$report" ]] && echo present || echo missing)"
    rc=1
  fi
}
check ZAP "$ZAP_OUTCOME" report_json.json
check Nuclei "$NUCLEI_OUTCOME" nuclei-results.jsonl
exit "$rc"
