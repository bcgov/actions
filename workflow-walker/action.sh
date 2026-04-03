#!/bin/bash
set -euo pipefail

# Workflow Walker: Forensic Multi-Image Discovery
# Optimized for minimal GHCR API calls using 'crane ls'

# Inputs
IMAGES_INPUT="${INPUT_IMAGES:-}"
MAX_DEPTH="${INPUT_MAX_DEPTH:-1000}"
DEBUG="${INPUT_DEBUG:-false}"

if [ "$DEBUG" == "true" ]; then
  set -x
fi

# 1. Parse image inputs into components and image paths
# Expected format: "component1=ghcr.io/repo/img1 component2=ghcr.io/repo/img2"
read -ra IMAGE_ARR <<< "$IMAGES_INPUT"

declare -A COMPONENT_IMAGES
declare -A COMPONENT_TAG_LISTS
declare -A RESOLVED_SHAS

echo "::group::Forensic Walk — State Discovery"
for ENTRY in "${IMAGE_ARR[@]}"; do
  IFS='=' read -r COMP REPO <<< "$ENTRY"
  COMPONENT_IMAGES["$COMP"]="$REPO"
  
  echo "Fetching existing tags for $COMP [$REPO]..."
  # Optimization: Call crane ls ONCE per repo to get all tags
  # We filter for sha-* tags specifically
  TAGS=$(crane ls "$REPO" 2>/dev/null | grep '^sha-' || true)
  COMPONENT_TAG_LISTS["$COMP"]="$TAGS"
  
  if [ -z "$TAGS" ]; then
    echo "::warning::No sha- tags found for component $COMP at $REPO. Walker will likely fail to resolve this component."
  fi
done
echo "::endgroup::"

# 2. Walk Git history of the current branch (assumed main if on prod)
echo "::group::Forensic Walk — History Discovery"

# We get the list of recent SHAs from git locally
GIT_REVS=$(git rev-list --max-count="$MAX_DEPTH" HEAD)

for COMP in "${!COMPONENT_IMAGES[@]}"; do
  echo "Resolving component: $COMP"
  RESOLVED=false
  
  for SHA in $GIT_REVS; do
    SHORT_SHA="sha-${SHA:0:7}"
    # LONG_SHA variant (check both standard patterns just in case)
    FULL_SHA_TAG="sha-$SHA"
    
    # Check our local tag list (No API call inside loop!)
    if echo "${COMPONENT_TAG_LISTS[$COMP]}" | grep -q "$SHORT_SHA\|$FULL_SHA_TAG"; then
       echo "  ✅ Resolved: $COMP -> $SHA"
       RESOLVED_SHAS["$COMP"]="$SHA"
       RESOLVED=true
       break
    fi
  done

  if [ "$RESOLVED" == "false" ]; then
     echo "::error::Could not find a valid build manifest for $COMP within last $MAX_DEPTH commits."
     exit 1
  fi
done
echo "::endgroup::"

# 3. Output the bundle
BUNDLE=""
for COMP in "${!RESOLVED_SHAS[@]}"; do
  BUNDLE="$BUNDLE $COMP=${RESOLVED_SHAS[$COMP]}"
done

echo "bundle_shas=${BUNDLE# }" >> "$GITHUB_OUTPUT"
echo "::notice title=Workflow Walker::✅ Forensic Bundle Resolved: ${BUNDLE# }"
