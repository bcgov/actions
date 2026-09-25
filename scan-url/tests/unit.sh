#!/usr/bin/env bash
# Unit tests for zap-sarif.jq (ZAP JSON -> SARIF) and verify.sh. No network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ_FILTER="${SCRIPT_DIR}/../zap-sarif.jq"
FIXTURE="${SCRIPT_DIR}/report_json.json"

passed=0
failed=0

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $name"
    passed=$((passed + 1))
  else
    echo "✗ $name: expected '$expected', got '$actual'"
    failed=$((failed + 1))
  fi
}

sarif="$(jq -f "$JQ_FILTER" "$FIXTURE")"
q() { jq -r "$1" <<<"$sarif"; }

assert_eq "$(q .version)" "2.1.0" "SARIF version"
assert_eq "$(q '.runs[0].tool.driver.name')" "ZAP" "tool name"
assert_eq "$(q '.runs[0].results | length')" "$(jq '[.site[].alerts[].instances[]] | length' "$FIXTURE")" "one result per alert instance"
assert_eq "$(q '.runs[0].tool.driver.rules | length')" "$(jq '[.site[].alerts[].alertRef] | unique | length' "$FIXTURE")" "one rule per alertRef"
assert_eq "$(q '[.runs[0].results[].ruleId] - [.runs[0].tool.driver.rules[].id] | length')" "0" "every result references a rule"
assert_eq "$(q '[.runs[0].results[].level] | unique | join(",")')" "$(jq -r '[.site[].alerts[].riskcode | {"3": "error", "2": "warning"}[.] // "note"] | unique | join(",")' "$FIXTURE")" "riskcode maps to level"
assert_eq "$(q '[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri | select(test("^[a-z]+://"))] | length')" "0" "URI scheme stripped"
assert_eq "$(q '[.runs[0].tool.driver.rules[].fullDescription.text | select(test("<"))] | length')" "0" "HTML stripped from descriptions"

for empty in '{}' '{"site":[]}' '{"site":[{"@name":"x","alerts":[]}]}'; do
  assert_eq "$(jq -c -f "$JQ_FILTER" <<<"$empty" | jq -c '[.runs[0].results, .runs[0].tool.driver.rules]')" "[[],[]]" "empty report: $empty"
done

# verify.sh: findings never fail; failed step or missing report does
VERIFY="${SCRIPT_DIR}/../verify.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
verify_rc() {
  local zap="$1" nuclei="$2"; shift 2
  rm -f "$WORK"/*
  for f in "$@"; do touch "$WORK/$f"; done
  (cd "$WORK" && ZAP_ENABLED="${ZAP_ENABLED:-true}" NUCLEI_ENABLED="${NUCLEI_ENABLED:-true}" \
    ZAP_OUTCOME="$zap" NUCLEI_OUTCOME="$nuclei" bash "$VERIFY" >/dev/null) && echo 0 || echo 1
}
assert_eq "$(verify_rc success success report_json.json nuclei-results.jsonl)" "0" "verify: both scans completed"
assert_eq "$(verify_rc failure success report_json.json nuclei-results.jsonl)" "1" "verify: ZAP step failed"
assert_eq "$(verify_rc success failure report_json.json nuclei-results.jsonl)" "1" "verify: Nuclei step failed"
assert_eq "$(verify_rc success success nuclei-results.jsonl)" "1" "verify: ZAP report missing"
assert_eq "$(verify_rc success success report_json.json)" "1" "verify: Nuclei JSONL missing"
assert_eq "$(NUCLEI_ENABLED=false verify_rc success skipped report_json.json)" "0" "verify: Nuclei disabled is not checked"
assert_eq "$(ZAP_ENABLED=false verify_rc skipped success nuclei-results.jsonl)" "0" "verify: ZAP disabled is not checked"
assert_eq "$(ZAP_ENABLED=false verify_rc skipped failure nuclei-results.jsonl)" "1" "verify: enabled Nuclei still checked"

echo "Passed: $passed, Failed: $failed"
[[ "$failed" -eq 0 ]]
