#!/usr/bin/env bash
# Validate the optional scan-narrowing inputs and print them as step outputs
# (key=value lines for $GITHUB_OUTPUT). Empty inputs print empty values, so the
# scanners get no extra flags and run exactly as they do without these inputs.
# Env: INPUT_NUCLEI_TAGS, INPUT_NUCLEI_TEMPLATES (lists, one item per line),
# INPUT_ZAP_SPIDER_MINUTES, INPUT_ZAP_SCAN_MINUTES (whole numbers), SHARED_INPUTS
# (path to shared/inputs.js). Values reach the scanners as arguments, never as script text.

set -euo pipefail

rc=0

# One item per line (shared/inputs.js), each matching pattern; printed comma-joined,
# which is how Nuclei's -tags and -t split values
list() {
  local name="$1" pattern="$2" what="$3" items item joined=""
  items="$(node "$SHARED_INPUTS" list "$name")" || { rc=1; echo "${name}="; return 0; }
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ ! "$item" =~ $pattern ]]; then
      echo "::error::${name} items must be ${what}, got '${item}'" >&2
      rc=1
      continue
    fi
    joined+="${joined:+,}${item}"
  done <<<"$items"
  echo "${name}=${joined}"
}

# Optional whole number from 1 to 9999; empty means not set
minutes() {
  local name="$1" value="$2"
  if [[ -n "$value" && ! "$value" =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "::error::${name} must be empty or a whole number from 1 to 9999, got '${value}'" >&2
    rc=1
    value=""
  fi
  echo "${name}=${value}"
  printf -v "$name" '%s' "$value"
}

list nuclei_tags '^[A-Za-z0-9][A-Za-z0-9_.-]*$' 'tag names (letters, digits, . _ -)'
list nuclei_templates '^[A-Za-z0-9_./][A-Za-z0-9_./-]*$' 'template or directory paths (letters, digits, . _ / -)'
minutes zap_spider_minutes "${INPUT_ZAP_SPIDER_MINUTES:-}"
minutes zap_scan_minutes "${INPUT_ZAP_SCAN_MINUTES:-}"

# zaproxy/action-full-scan appends cmd_options to zap-full-scan.py's arguments.
# -m caps the spider; scanner.maxScanDurationInMins (passed to ZAP with -z) caps
# the active scan. zap-full-scan.py's -T only caps the wait for ZAP to start and
# for the passive scan, not the active scan.
opts=()
[[ -z "$zap_spider_minutes" ]] || opts+=(-m "$zap_spider_minutes")
[[ -z "$zap_scan_minutes" ]] || opts+=(-z "\"-config scanner.maxScanDurationInMins=${zap_scan_minutes}\"")
echo "zap_cmd_options=${opts[*]}"

exit "$rc"
