#!/usr/bin/env bash
# Unit tests for zap-sarif.jq (ZAP JSON report -> SARIF). No network.

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

echo "Passed: $passed, Failed: $failed"
[[ "$failed" -eq 0 ]]
