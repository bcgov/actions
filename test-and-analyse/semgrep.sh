#!/usr/bin/env bash
# Semgrep scan of the current directory (the action's `dir`), in the pinned
# Semgrep container. Findings are warnings unless INPUT_SEMGREP_FAIL is true.
#
# Env: SEMGREP_IMAGE, INPUT_SEMGREP_CONFIG (one config per line),
#      INPUT_SEMGREP_FAIL (true/false), GITHUB_WORKSPACE, RUNNER_TEMP, GITHUB_OUTPUT
set -euo pipefail

: "${SEMGREP_IMAGE:?SEMGREP_IMAGE is required}"
: "${GITHUB_WORKSPACE:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}"

case "${INPUT_SEMGREP_FAIL:-false}" in
  true|false) ;;
  *) echo "::error::semgrep_fail must be true or false, got '${INPUT_SEMGREP_FAIL}'"; exit 1 ;;
esac
command -v docker >/dev/null 2>&1 || { echo "::error::The Semgrep scan needs Docker on the runner"; exit 1; }

workspace="$(cd "${GITHUB_WORKSPACE}" && pwd -P)"
target="$(pwd -P)"
case "${target}/" in
  "${workspace}"/*) ;;
  *) echo "::error::dir (${target}) must be inside the workspace (${workspace})"; exit 1 ;;
esac
rel="${target#"${workspace}"}"
rel="${rel#/}"

# Registry rulesets (p/..., r/...) pass through; other entries are files
# relative to the workspace root.
configs=()
while IFS= read -r c; do
  c="${c#"${c%%[![:space:]]*}"}"
  c="${c%"${c##*[![:space:]]}"}"
  [[ -n "$c" ]] || continue
  if [[ "$c" != p/* && "$c" != r/* ]]; then
    [[ -e "${workspace}/${c}" ]] || { echo "::error::Semgrep config not found: ${c} (relative to the workspace root)"; exit 1; }
    c="${workspace}/${c}"
  fi
  configs+=(--config "$c")
done <<< "${INPUT_SEMGREP_CONFIG:-p/default}"
[[ ${#configs[@]} -gt 0 ]] || { echo "::error::semgrep_config is empty"; exit 1; }

# Unique per run, so several scans in one job keep their own reports
out="$(mktemp -d "${RUNNER_TEMP}/semgrep.XXXXXX")"
json="${out}/semgrep.json"
sarif="${out}/semgrep.sarif"

# --error: exit 1 on findings, 0 when clean, anything else is a scan error
set +e
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e SEMGREP_SEND_METRICS=off \
  -v "${workspace}:${workspace}" -v "${out}:${out}" -w "${target}" \
  "${SEMGREP_IMAGE}" \
  semgrep scan "${configs[@]}" --metrics=off --error --json-output="$json" --sarif-output="$sarif" .
rc=$?
set -e
if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
  echo "::error::Semgrep scan failed (exit ${rc})"
  exit "$rc"
fi

# Error-level entries mean the scan is unreliable; warn-level ones (files
# that only partly parsed, timeouts) are reported but do not fail
errors="$(jq '[.errors[] | select(.level == "error")] | length' "$json")"
skipped="$(jq '[.errors[] | select(.level != "error")] | length' "$json")"
if [[ "$errors" -gt 0 ]]; then
  jq -r '.errors[] | select(.level == "error") | .message' "$json"
  echo "::error::Semgrep reported ${errors} scan error(s)"
  exit 1
fi
[[ "$skipped" -eq 0 ]] || echo "::warning::Semgrep: ${skipped} file(s) or rule(s) not fully scanned; see the log above"

# SARIF paths are relative to dir; make them relative to the workspace root
# so an upload maps them to the right files
if [[ -n "$rel" ]]; then
  jq --arg p "${rel}/" 'walk(if type == "object" and (.artifactLocation.uri? | type) == "string"
    then .artifactLocation.uri = $p + .artifactLocation.uri else . end)' "$sarif" > "${sarif}.tmp"
  mv "${sarif}.tmp" "$sarif"
fi

count="$(jq '.results | length' "$json")"
{
  echo "semgrep_findings=${count}"
  echo "semgrep_sarif=${sarif}"
} >> "$GITHUB_OUTPUT"

# One annotation per finding (first 50), paths relative to the workspace root
jq -r --arg rel "$rel" '
  def esc: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  def prop: esc | gsub(":"; "%3A") | gsub(","; "%2C");
  .results[:50][] |
  ((if $rel == "" then "" else $rel + "/" end) + .path) as $p |
  "::warning file=\($p | prop),line=\(.start.line),title=\("Semgrep " + .check_id | prop)::\(.extra.message | esc)"' "$json"

if [[ "$count" -eq 0 ]]; then
  echo "Semgrep: no findings"
elif [[ "${INPUT_SEMGREP_FAIL:-false}" == "true" ]]; then
  echo "::error::Semgrep: ${count} finding(s); failing because semgrep_fail is true"
  exit 1
else
  echo "::warning::Semgrep: ${count} finding(s); not failing (set semgrep_fail: true to fail)"
fi
