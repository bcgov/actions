#!/usr/bin/env bash
# Unit tests for zap-sarif.jq (ZAP JSON -> SARIF), verify.sh, nuclei-skipped.sh, options.sh and nuclei-sarif.sh. No network.

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

# nuclei-skipped.sh: Nuclei skipping the scanned host:port fails (and so does
# the Nuclei Scan step, which verify.sh then reports); another host or port warns.
# nuclei-unresponsive-permanently.txt is the Nuclei Scan output from
# bcgov/quickstart-openshift run 44897163143 (2026-11-21), timestamps removed.
# The other two are nuclei v3.11.1 runs against local servers (a server that
# never answers, and python http.server), with 127.0.0.1 renamed scan-url.example.
SKIPPED="${SCRIPT_DIR}/../nuclei-skipped.sh"
FIXTURES="${SCRIPT_DIR}/fixtures"
skipped_rc() {
  local url="$1" log="$2"
  rm -f "$WORK"/*
  cp "${FIXTURES}/${log}" "$WORK/nuclei.log" || { echo "missing fixture ${log}"; return; }
  (cd "$WORK" && URL="$url" bash "$SKIPPED" > "$WORK/skipped.out") && echo 0 || echo 1
}
QS=https://quickstart-openshift-test.apps.silver.devops.gov.bc.ca
assert_eq "$(skipped_rc "$QS" nuclei-unresponsive-permanently.txt)" "1" "nuclei-skipped: 'unresponsive permanently' fails"
assert_eq "$(grep -c '^::error::Nuclei did not complete: Skipped quickstart-openshift-test.apps.silver.devops.gov.bc.ca:443 from target list as found unresponsive permanently' "$WORK/skipped.out")" "1" "nuclei-skipped: one error per skipped host:port"
assert_eq "$(skipped_rc "${QS}/api" nuclei-unresponsive-permanently.txt)" "1" "nuclei-skipped: URL path still maps to port 443"
assert_eq "$(skipped_rc https://scan-url.example nuclei-unresponsive-times.txt)" "1" "nuclei-skipped: 'unresponsive N times' fails"
assert_eq "$(skipped_rc https://Scan-URL.example nuclei-unresponsive-times.txt)" "1" "nuclei-skipped: host match ignores case"
assert_eq "$(skipped_rc https://other.example nuclei-unresponsive-times.txt)" "0" "nuclei-skipped: another host's skip only warns"
assert_eq "$(skipped_rc http://scan-url.example nuclei-clean.txt)" "0" "nuclei-skipped: normal Nuclei log passes"
assert_eq "$(grep -c '^::warning::Nuclei Skipped scan-url.example:5814' "$WORK/skipped.out")" "1" "nuclei-skipped: another port's skip only warns"
assert_eq "$(grep -c '^::error::' "$WORK/skipped.out")" "0" "nuclei-skipped: normal log has no errors"
assert_eq "$(skipped_rc http://scan-url.example:5814 nuclei-clean.txt)" "1" "nuclei-skipped: explicit URL port is the one checked"
APP=https://app.example.gov.bc.ca
assert_eq "$(skipped_rc "$APP" nuclei-unresponsive-other-ip.txt)" "0" "nuclei-skipped: third-party IPv4/IPv6 on the scanned port only warns"
assert_eq "$(grep -c '^::warning::' "$WORK/skipped.out")" "2" "nuclei-skipped: one warning per third-party IP"
assert_eq "$(skipped_rc "$APP" nuclei-unresponsive-target-ip.txt)" "1" "nuclei-skipped: IP skip whose line names the scanned host fails"
assert_eq "$(grep -c '^::error::Nuclei did not complete: Skipped 198.51.100.7:443' "$WORK/skipped.out")" "1" "nuclei-skipped: error names the IP key"
assert_eq "$(grep -c '^::warning::Nuclei Skipped \[2001:db8::7\]:443' "$WORK/skipped.out")" "1" "nuclei-skipped: IPv6 skip not naming the host only warns"
assert_eq "$(skipped_rc http://app.example.gov.bc.ca nuclei-unresponsive-target-ip.txt)" "0" "nuclei-skipped: IP skip on another port only warns"
rm -f "$WORK"/*
assert_eq "$( (cd "$WORK" && URL="$QS" bash "$SKIPPED" >/dev/null) && echo 0 || echo 1)" "0" "nuclei-skipped: no nuclei.log passes"
assert_eq "$(grep -cF 'nuclei-skipped.sh"' "${SCRIPT_DIR}/../action.yml")" "1" "action.yml runs nuclei-skipped.sh in the Nuclei Scan step"

ACTION_YML="${SCRIPT_DIR}/../action.yml"
assert_eq "$(grep -c 'allow_issue_writing: false' "$ACTION_YML")" "1" "action.yml disables duplicate ZAP issue writing"

# options.sh: optional scan-depth inputs. Unset adds no scanner flags; bad values fail.
OPTIONS="${SCRIPT_DIR}/../options.sh"
SHARED="${SCRIPT_DIR}/../../shared/inputs.js"
options() {
  # Args: tags templates spider_minutes scan_minutes; prints outputs, then rc=<exit>
  local rc=0
  INPUT_NUCLEI_TAGS="$1" INPUT_NUCLEI_TEMPLATES="$2" INPUT_ZAP_SPIDER_MINUTES="$3" \
    INPUT_ZAP_SCAN_MINUTES="$4" SHARED_INPUTS="$SHARED" bash "$OPTIONS" 2>/dev/null || rc=$?
  echo "rc=${rc}"
}
out() { grep "^$1=" <<<"$2" | cut -d= -f2-; }
o="$(options '' '' '' '')"
assert_eq "$(out rc "$o")" "0" "options: all unset passes"
assert_eq "$(grep -c '^[a-z_]*=$' <<<"$o")" "5" "options: unset prints only empty values (no scanner flags)"
o="$(options tech '' '' '')"
assert_eq "$(out nuclei_tags "$o")" "tech" "options: single tag"
o="$(options _internal '' '' '')"
assert_eq "$(out nuclei_tags "$o")" "_internal" "options: tag may start with _ or ."
o="$(options $'tech\n\ncve\n' '' '' '')"
assert_eq "$(out nuclei_tags "$o")" "tech,cve" "options: tags one per line, blank lines skipped, comma-joined for -tags"
o="$(options '' $'http/technologies/\ndns/caa-fingerprint.yaml' '' '')"
assert_eq "$(out nuclei_templates "$o")" "http/technologies/,dns/caa-fingerprint.yaml" "options: templates one per line, comma-joined for -t"
o="$(options '' '' 1 5)"
assert_eq "$(out zap_cmd_options "$o")" '-m 1 -z "-config scanner.maxScanDurationInMins=5"' "options: ZAP spider and active scan caps"
o="$(options '' '' 2 '')"
assert_eq "$(out zap_cmd_options "$o")" "-m 2" "options: ZAP spider cap only"
o="$(options '' '' '' 9999)"
assert_eq "$(out zap_cmd_options "$o")" '-z "-config scanner.maxScanDurationInMins=9999"' "options: ZAP active scan cap only"
assert_eq "$(out rc "$(options 'tech, cve' '' '' '')")" "1" "options: comma-separated tags fail (one per line)"
assert_eq "$(out rc "$(options 'tech;id' '' '' '')")" "1" "options: tag with ; fails"
assert_eq "$(out rc "$(options '-silent' '' '' '')")" "1" "options: tag that looks like a flag fails"
# shellcheck disable=SC2016 # literal shell syntax is the input under test
assert_eq "$(out rc "$(options '$(id)' '' '' '')")" "1" "options: tag with shell syntax fails"
assert_eq "$(out rc "$(options '' '-u' '' '')")" "1" "options: template that looks like a flag fails"
# shellcheck disable=SC2016 # literal shell syntax is the input under test
assert_eq "$(out rc "$(options '' 'a`id`' '' '')")" "1" "options: template with backticks fails"
for bad in 0 01 10000 -1 1.5 '5;id' '5 -z x' abc; do
  assert_eq "$(out rc "$(options '' '' "$bad" '')")" "1" "options: zap_spider_minutes '${bad}' fails"
  assert_eq "$(out rc "$(options '' '' '' "$bad")")" "1" "options: zap_scan_minutes '${bad}' fails"
done
# shellcheck disable=SC2016 # literal action.yml text, not shell
assert_eq "$(grep -c 'cmd_options: ${{ steps.preflight.outputs.zap_cmd_options }}' "$ACTION_YML")" "1" "action.yml passes ZAP caps as cmd_options"
# shellcheck disable=SC2016 # literal action.yml text, not shell
assert_eq "$(grep -cE '\[\[ -z "\$(TAGS|TEMPLATES)" \]\] \|\| args\+=\(-(tags|t) "\$(TAGS|TEMPLATES)"\)' "$ACTION_YML")" "2" "action.yml adds -tags/-t as arguments only when set"
assert_eq "$(grep -cE 'inputs\.(nuclei_tags|nuclei_templates|zap_spider_minutes|zap_scan_minutes) \}\}' "$ACTION_YML")" "4" "action.yml reads the new inputs only through env"
assert_eq "$(awk '/^  nuclei_tags:/{f=1;next} f && /^  [a-z_]+:/{exit} f && /^      /{gsub(/^ +/,""); printf "%s%s", (s?",":""), $0; s=1}' "$ACTION_YML")" "misconfig,exposure,tech" "action.yml defaults nuclei_tags to misconfig,exposure,tech"
assert_eq "$(grep -c -- '-retries "\$RETRIES" -nmhe' "$ACTION_YML")" "1" "action.yml passes -retries and -nmhe to nuclei"

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
