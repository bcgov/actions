#!/usr/bin/env bash
# Copy bundles built in this job over the `uses: $/...` download of the running commit.
# `$/` loads this repository at the workflow commit, and dist/ is only committed on
# release commits, so suite tests build dist/ first and stage it here.
# Usage: bash .github/scripts/stage-dist.sh <action-dir>...
set -euo pipefail

: "${RUNNER_WORKSPACE:?RUNNER_WORKSPACE is not set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
: "${GITHUB_WORKFLOW_SHA:?GITHUB_WORKFLOW_SHA is not set}"

dest="$(dirname "$RUNNER_WORKSPACE")/_actions/${GITHUB_REPOSITORY}/${GITHUB_WORKFLOW_SHA}"
if [ ! -d "$dest" ]; then
  echo "::error::No \$/ action download at ${dest}. Stage dist/ in a job whose steps use \$/." >&2
  exit 1
fi

for action in "$@"; do
  if [ ! -f "${action}/dist/index.js" ]; then
    echo "::error::${action}/dist/index.js is missing. Run npm run build first." >&2
    exit 1
  fi
  rm -rf "${dest:?}/${action}/dist"
  cp -R "${action}/dist" "${dest}/${action}/dist"
  echo "Staged ${action}/dist into ${dest}/${action}/dist"
done
