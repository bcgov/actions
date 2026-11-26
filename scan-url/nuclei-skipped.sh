#!/usr/bin/env bash
# Exit 1 when Nuclei skipped the scanned host:port as unresponsive.
# Nuclei drops a host:port after timeouts ("unresponsive permanently" or
# "unresponsive N times"), skips its remaining templates and still exits 0.
# The scanned host:port (or an IP on that port, when Nuclei logs the resolved
# address) means the scan is incomplete. Another port or host (a template
# probing :8443 or a third-party site) only warns.
# Env: URL (the scanned URL). Reads nuclei.log (Nuclei's output) from the cwd.

set -euo pipefail

[[ -f nuclei.log ]] || exit 0

host="$(sed -nE 's#^[a-zA-Z]+://([^/:]+).*#\1#p' <<<"${URL:-}" | tr '[:upper:]' '[:lower:]')"
port="$(sed -nE 's#^[a-zA-Z]+://[^/:]+:([0-9]+).*#\1#p' <<<"${URL:-}")"
[[ -n "$port" ]] || { [[ "${URL:-}" == http://* ]] && port=80 || port=443; }

skipped="$(sed 's/\x1b\[[0-9;]*m//g' nuclei.log \
  | grep -oE 'Skipped [^ ]+ from target list as found unresponsive( permanently| [0-9]+ times)' \
  | awk '!seen[$2]++' || true)"

rc=0
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
exit "$rc"
