// Findings fixture: one call matched by fixtures/semgrep/rules.yml.
function semgrepTestMarker(value) {
  return value
}
export const result = semgrepTestMarker('fixture')
