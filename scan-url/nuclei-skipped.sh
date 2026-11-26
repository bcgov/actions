#!/usr/bin/env bash
# Exit 1 when Nuclei skipped the scanned host:port as unresponsive.
# Nuclei drops a host:port after timeouts ("unresponsive permanently" or
# "unresponsive N times"), skips its remaining templates and still exits 0.
# Fails when the skip key is the scanned host:port, or is an IP / [IPv6] on
# that port (Nuclei can key on the TCP peer) and the same line names the
# scanned host (address=, chain=, or the request URL). Any other host or port
# (a template probing :8443, or a third-party site logged by name or IP) only warns.
# Env: URL (the scanned URL). Reads nuclei.log (Nuclei's output) from the cwd.

set -euo pipefail

[[ -f nuclei.log ]] || exit 0

host="$(sed -nE 's#^[a-zA-Z]+://([^/:]+).*#\1#p' <<<"${URL:-}" | tr '[:upper:]' '[:lower:]')"
port="$(sed -nE 's#^[a-zA-Z]+://[^/:]+:([0-9]+).*#\1#p' <<<"${URL:-}")"
[[ -n "$port" ]] || { [[ "${URL:-}" == http://* ]] && port=80 || port=443; }
# Host as a whole name in a line: not part of a longer hostname
host_re="(^|[^a-z0-9.-])${host//./\\.}([:/\" ]|$)"

lines="$(sed 's/\x1b\[[0-9;]*m//g' nuclei.log \
  | grep -E 'Skipped [^ ]+ from target list as found unresponsive( permanently| [0-9]+ times)' || true)"

declare -A verdict=() summary=()
order=()
while IFS= read -r raw; do
  [[ -n "$raw" ]] || continue
  line="$(grep -oE 'Skipped [^ ]+ from target list as found unresponsive( permanently| [0-9]+ times)' <<<"$raw")"
  address="$(cut -d' ' -f2 <<<"$line" | tr '[:upper:]' '[:lower:]')"
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$raw")"
  target=false
  if [[ "$address" == "${host}:${port}" ]]; then
    target=true
  elif [[ "$address" =~ ^([0-9]+(\.[0-9]+){3}|\[[0-9a-f:.]+\]):${port}$ ]] && [[ "$lower" =~ $host_re ]]; then
    target=true
  fi
  if [[ -z "${verdict[$address]+x}" ]]; then
    order+=("$address")
    verdict[$address]=$target
    summary[$address]="$line"
  elif [[ "$target" == true ]]; then
    verdict[$address]=true
  fi
done <<<"$lines"

rc=0
for address in "${order[@]}"; do
  if [[ "${verdict[$address]}" == true ]]; then
    echo "::error::Nuclei did not complete: ${summary[$address]}; its remaining templates did not run. Lower nuclei_rate_limit or nuclei_concurrency, or raise nuclei_timeout"
    rc=1
  else
    echo "::warning::Nuclei ${summary[$address]}; ${host}:${port} was still scanned"
  fi
done
exit "$rc"
