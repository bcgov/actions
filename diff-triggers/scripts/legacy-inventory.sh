#!/usr/bin/env bash
# Count bcgov workflows still using the legacy diff-triggers formats (#218).
# Run it under your own gh login; code search needs a user token, and the
# Actions token is rate limited out of it.  Read-only: it only searches.
#
# Usage: diff-triggers/scripts/legacy-inventory.sh
#
# Removing the legacy parsers is safe once the parenthesized org count is zero,
# apart from archived repos and intentional test fixtures.
set -euo pipefail

searches=(
  "Parenthesized (org)|org:bcgov \"triggers: (\""
  "Comma-separated (org)|org:bcgov \"triggers: backend/,\""
  "Semicolon-separated (org)|org:bcgov \"triggers: backend/;\""
  "Parenthesized (bcgov/actions)|repo:bcgov/actions \"triggers: (\""
  "Parenthesized (bcgov/quickstart-openshift)|repo:bcgov/quickstart-openshift \"triggers: (\""
)

echo "Legacy diff-triggers inventory ($(date -u +%Y-%m-%d))"
echo
repos=""
for entry in "${searches[@]}"; do
  label="${entry%%|*}"
  query="${entry#*|}"
  result="$(gh api -X GET search/code -f q="$query" -F per_page=100)"
  total="$(jq '.total_count' <<< "$result")"
  count="$(jq '[.items[].repository.full_name] | unique | length' <<< "$result")"
  printf '%-45s %5s files (%s repos in the first 100 hits)\n' "$label" "$total" "$count"
  if [ "$label" = "Parenthesized (org)" ]; then
    repos="$(jq -r '.items[].repository.full_name' <<< "$result" | sort | uniq -c | sort -rn)"
  fi
  # Code search allows 10 requests a minute
  sleep 7
done

echo
echo "Repos with parenthesized triggers (first 100 hits, files per repo):"
echo "$repos"
