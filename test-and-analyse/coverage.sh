#!/usr/bin/env bash
# Coverage floor for the current directory (the action's working_directory).
# Reads the line coverage total from the report the caller's commands wrote and
# fails when it is missing or below INPUT_MIN_COVERAGE.
#
#   node:   coverage/coverage-summary.json   (Istanbul json-summary: Jest, Vitest)
#   python: coverage.xml                     (Cobertura: pytest --cov-report=xml)
#   java:   target/site/jacoco/jacoco.xml    (JaCoCo XML: Maven jacoco:report)
#           build/reports/jacoco/test/jacocoTestReport.xml (Gradle)
#
# Env: INPUT_MIN_COVERAGE (0-100, decimals allowed), INPUT_LANGUAGE (node/java/python)
set -euo pipefail

min="${INPUT_MIN_COVERAGE:?INPUT_MIN_COVERAGE is required}"
lang="${INPUT_LANGUAGE:?INPUT_LANGUAGE is required}"

if ! [[ "$min" =~ ^[0-9]+(\.[0-9]+)?$ ]] || awk -v m="$min" 'BEGIN { exit !(m > 100) }'; then
  echo "::error title=min_coverage::min_coverage must be a number from 0 to 100, got '${min}'"
  exit 1
fi

case "$lang" in
  node) reports=(coverage/coverage-summary.json) ;;
  python) reports=(coverage.xml) ;;
  java) reports=(target/site/jacoco/jacoco.xml build/reports/jacoco/test/jacocoTestReport.xml) ;;
  *) echo "::error::Unsupported language for min_coverage: ${lang}"; exit 1 ;;
esac

report=""
for r in "${reports[@]}"; do
  if [[ -f "$r" ]]; then report="$r"; break; fi
done
if [[ -z "$report" ]]; then
  hint=""
  case "$lang" in
    node) hint="Add the json-summary reporter (Jest: --coverageReporters=json-summary, Vitest: --coverage.reporter=json-summary)." ;;
    python) hint="Add --cov-report=xml to pytest." ;;
    java) hint="Generate a JaCoCo XML report (Maven jacoco:report or Gradle jacocoTestReport)." ;;
  esac
  echo "::error title=min_coverage::No coverage report in $(pwd): expected ${reports[*]}. ${hint}"
  exit 1
fi

case "$lang" in
  node)
    pct="$(jq -er '.total.lines.pct | numbers' "$report")" || {
      echo "::error title=min_coverage::${report} has no numeric total.lines.pct"; exit 1; }
    ;;
  python)
    # Root <coverage line-rate="0.873"> (0-1)
    rate="$(grep -o '<coverage [^>]*' "$report" | grep -o 'line-rate="[0-9.]*"' | head -n1 | grep -o '[0-9.]*' || true)"
    [[ -n "$rate" ]] || { echo "::error title=min_coverage::${report} has no line-rate on <coverage>"; exit 1; }
    pct="$(awk -v r="$rate" 'BEGIN { printf "%.2f", r * 100 }')"
    ;;
  java)
    # Report-level LINE counter is the last one in the file
    counter="$(grep -o '<counter type="LINE"[^>]*>' "$report" | tail -n1 || true)"
    missed="$(grep -o 'missed="[0-9]*"' <<< "$counter" | grep -o '[0-9]*' || true)"
    covered="$(grep -o 'covered="[0-9]*"' <<< "$counter" | grep -o '[0-9]*' || true)"
    [[ -n "$missed" && -n "$covered" ]] || { echo "::error title=min_coverage::${report} has no LINE counter"; exit 1; }
    pct="$(awk -v m="$missed" -v c="$covered" 'BEGIN { t = m + c; printf "%.2f", (t ? c * 100 / t : 0) }')"
    ;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "coverage=${pct}" >> "$GITHUB_OUTPUT"
fi
if awk -v p="$pct" -v m="$min" 'BEGIN { exit !(p + 0 < m + 0) }'; then
  echo "::error title=min_coverage::Line coverage ${pct}% is below min_coverage ${min}% (${report})"
  exit 1
fi
echo "Line coverage ${pct}% meets min_coverage ${min}% (${report})"
