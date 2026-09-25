#!/usr/bin/env bash
# Findings never fail the action; a failed scanner step or missing report does.
# Env: ZAP_ENABLED, NUCLEI_ENABLED ('true'/'false'), ZAP_OUTCOME, NUCLEI_OUTCOME
# (step outcomes). Disabled scanners are not checked. Reads reports from the cwd.

set -euo pipefail

rc=0
check() {
  local name="$1" enabled="$2" outcome="$3" report="$4"
  [[ "$enabled" == true ]] || return 0
  if [[ "$outcome" != success || ! -f "$report" ]]; then
    echo "::error::${name} did not complete: step ${outcome}, ${report} $([[ -f "$report" ]] && echo present || echo missing)"
    rc=1
  fi
}
check ZAP "$ZAP_ENABLED" "$ZAP_OUTCOME" report_json.json
check Nuclei "$NUCLEI_ENABLED" "$NUCLEI_OUTCOME" nuclei-results.jsonl
exit "$rc"
