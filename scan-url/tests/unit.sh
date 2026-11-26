#!/usr/bin/env bash
# Unit tests for zap-sarif.jq (ZAP JSON -> SARIF), verify.sh and nuclei-sarif.sh. No network.

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

# verify.sh: Nuclei skipping the scanned host:port fails; another port only warns.
# nuclei-unresponsive-permanently.txt is the Nuclei Scan output from
# bcgov/quickstart-openshift run 44897163143 (2026-11-21), timestamps removed.
# The other two are nuclei v3.11.1 runs against local servers (a server that
# never answers, and python http.server), with 127.0.0.1 renamed scan-url.example.
FIXTURES="${SCRIPT_DIR}/fixtures"
verify_log() {
  local url="$1" log="$2"
  rm -f "$WORK"/*
  touch "$WORK/report_json.json" "$WORK/nuclei-results.jsonl"
  cp "${FIXTURES}/${log}" "$WORK/nuclei.log" || { echo "missing fixture ${log}"; return; }
  (cd "$WORK" && URL="$url" ZAP_ENABLED=true NUCLEI_ENABLED="${NUCLEI_ENABLED:-true}" \
    ZAP_OUTCOME=success NUCLEI_OUTCOME=success bash "$VERIFY" > "$WORK/verify.out") && echo 0 || echo 1
}
QS=https://quickstart-openshift-test.apps.silver.devops.gov.bc.ca
assert_eq "$(verify_log "$QS" nuclei-unresponsive-permanently.txt)" "1" "verify: Nuclei 'unresponsive permanently' fails"
assert_eq "$(grep -c '^::error::Nuclei did not complete: Skipped quickstart-openshift-test.apps.silver.devops.gov.bc.ca:443 from target list as found unresponsive permanently' "$WORK/verify.out")" "1" "verify: one error per skipped host:port"
assert_eq "$(verify_log "${QS}/api" nuclei-unresponsive-permanently.txt)" "1" "verify: URL path still maps to port 443"
assert_eq "$(verify_log https://scan-url.example nuclei-unresponsive-times.txt)" "1" "verify: Nuclei 'unresponsive N times' fails"
assert_eq "$(verify_log http://scan-url.example nuclei-clean.txt)" "0" "verify: normal Nuclei log passes"
assert_eq "$(grep -c '^::warning::Nuclei Skipped scan-url.example:5814' "$WORK/verify.out")" "1" "verify: another port's skip only warns"
assert_eq "$(verify_log http://scan-url.example:5814 nuclei-clean.txt)" "1" "verify: explicit URL port is the one checked"
assert_eq "$(verify_log https://other.example nuclei-unresponsive-times.txt)" "0" "verify: another host's skip only warns"
assert_eq "$(verify_log https://Scan-URL.example nuclei-unresponsive-times.txt)" "1" "verify: host match ignores case"
assert_eq "$(NUCLEI_ENABLED=false verify_log "$QS" nuclei-unresponsive-permanently.txt)" "0" "verify: Nuclei disabled ignores nuclei.log"

ACTION_YML="${SCRIPT_DIR}/../action.yml"
assert_eq "$(grep -c 'allow_issue_writing: false' "$ACTION_YML")" "1" "action.yml disables duplicate ZAP issue writing"

# nuclei-sarif.sh: fixes executionSuccessful=false and creates empty SARIF on clean scan
NUCLEI_SARIF="${SCRIPT_DIR}/../nuclei-sarif.sh"
run_nuclei_sarif() {
  (cd "$WORK" && bash "$NUCLEI_SARIF")
}

rm -f "$WORK"/*
cat > "$WORK/nuclei-results.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Nuclei"}},"invocations":[{"commandLine":"nuclei","executionSuccessful":false}],"results":[{"ruleId":"r1"}]}]}
EOF
run_nuclei_sarif
assert_eq "$(jq -r '.runs[0].invocations[0].executionSuccessful' "$WORK/nuclei-results.sarif")" "true" "nuclei-sarif: flips executionSuccessful false to true"
assert_eq "$(jq -r '.runs[0].results[0].ruleId' "$WORK/nuclei-results.sarif")" "r1" "nuclei-sarif: preserves results"

rm -f "$WORK"/*
cat > "$WORK/nuclei-results.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Nuclei"}},"invocations":[{"executionSuccessful":true}],"results":[]}]}
EOF
run_nuclei_sarif
assert_eq "$(jq -r '.runs[0].invocations[0].executionSuccessful' "$WORK/nuclei-results.sarif")" "true" "nuclei-sarif: keeps executionSuccessful true unchanged"

rm -f "$WORK"/*
cat > "$WORK/nuclei-results.sarif" <<'EOF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Nuclei"}},"results":[]}]}
EOF
run_nuclei_sarif
assert_eq "$(jq -c '.runs[0] | has("invocations")' "$WORK/nuclei-results.sarif")" "false" "nuclei-sarif: leaves SARIF without invocations unchanged"

rm -f "$WORK"/*
touch "$WORK/nuclei-results.jsonl"
run_nuclei_sarif
assert_eq "$(jq -c '.runs[0].results' "$WORK/nuclei-results.sarif")" "[]" "nuclei-sarif: creates empty SARIF on clean scan"

rm -f "$WORK"/*
run_nuclei_sarif
assert_eq "$([[ -f "$WORK/nuclei-results.sarif" ]] && echo present || echo missing)" "missing" "nuclei-sarif: no files means no SARIF"

echo "Passed: $passed, Failed: $failed"
[[ "$failed" -eq 0 ]]
