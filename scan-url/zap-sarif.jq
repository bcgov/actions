# ZAP traditional JSON report (report_json.json) -> SARIF 2.1.0.
# riskcode: 3 High, 2 Medium, 1 Low, 0 Informational.
def level: {"3": "error", "2": "warning"}[.riskcode] // "note";
[.site[]?.alerts[]?] as $alerts
| {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [{
      tool: {driver: {
        name: "ZAP",
        informationUri: "https://www.zaproxy.org/",
        rules: ($alerts | unique_by(.alertRef) | map({
          id: .alertRef,
          shortDescription: {text: .name},
          fullDescription: {text: (.desc | gsub("<[^>]*>"; ""))},
          helpUri: "https://www.zaproxy.org/docs/alerts/\(.alertRef)/",
          defaultConfiguration: {level: level}
        }))
      }},
      results: [$alerts[] as $a | $a.instances[] | {
        ruleId: $a.alertRef,
        level: ($a | level),
        message: {text: "\($a.name): \(.method) \(.uri)"},
        locations: [{physicalLocation: {artifactLocation: {uri: (.uri | sub("^[a-z]+://"; ""))}}}]
      }]
    }]
  }
