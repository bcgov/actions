#!/usr/bin/env bash
# Findings never fail the action; a failed scanner step, a missing report, or
# Nuclei skipping an unresponsive target does.
# Env: ZAP_ENABLED, NUCLEI_ENABLED ('true'/'false'), ZAP_OUTCOME, NUCLEI_OUTCOME
# (step outcomes), URL (the scanned URL). Disabled scanners are not checked.
# Reads reports and nuclei.log (the Nuclei Scan step's output) from the cwd.

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

# Nuclei drops a host:port after timeouts ("unresponsive permanently" or
# "unresponsive N times"), skips its remaining templates and still exits 0.
# The scanned host:port (or an IP on that port, when Nuclei logs the resolved
# address) failing means the scan is incomplete. Another port or host (a
# template probing :8443 or a third-party site) only warns.
if [[ "$NUCLEI_ENABLED" == true && -f nuclei.log ]]; then
  host="$(sed -nE 's#^[a-zA-Z]+://([^/:]+).*#\1#p' <<<"${URL:-}" | tr '[:upper:]' '[:lower:]')"
  port="$(sed -nE 's#^[a-zA-Z]+://[^/:]+:([0-9]+).*#\1#p' <<<"${URL:-}")"
  [[ -n "$port" ]] || { [[ "${URL:-}" == http://* ]] && port=80 || port=443; }
  skipped="$(sed 's/\x1b\[[0-9;]*m//g' nuclei.log \
    | grep -oE 'Skipped [^ ]+ from target list as found unresponsive( permanently| [0-9]+ times)' \
    | awk '!seen[$2]++' || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    address="$(cut -d' ' -f2 <<<"$line" | tr '[:upper:]' '[:lower:]')"
    if [[ "$address" == "${host}:${port}" || "$address" =~ ^[0-9.]+:${port}$ ]]; then
      echo "::error::Nuclei did not complete: ${line}; its remaining templates did not run. Lower nuclei_rate_limit or nuclei_concurrency, or raise nuclei_timeout"
      rc=1
    else
      echo "::warning::Nuclei ${line}; ${host}:${port} was still scanned"
    fi
  done <<<"$skipped"
fi
exit "$rc"
