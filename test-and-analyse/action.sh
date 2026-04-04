#!/usr/bin/env bash
set -euo pipefail

# test-and-analyse
# Orchestrates Node tests, SonarCloud analysis, and Knip dependency checks

echo "::group::Environment Information"
echo "Running Test & Analysis for component in: $DIR"
echo "Node version: $(node --version)"
# 1. Supply Chain Protection
if [[ "$SUPPLY_SCAN" == "true" ]]; then
  echo "::group::Supply Chain Scan (Safe-Chain)"
  # Ensure tools are installed (Should be pre-installed in runner or by composite)
  safe-chain setup-ci
  echo "::endgroup::"
fi

# 2. Run Tests
echo "::group::Running Component Tests"
pushd "$DIR"
npm install
eval "$COMMANDS"
popd
# 3. Dependency Analysis (Knip)
if [[ "$DEP_SCAN" != "off" ]]; then
  echo "::group::Dependency Analysis (Knip)"
  pushd "$DIR"

  # Determine config
  if [[ -n "$KNIP_CONFIG" ]]; then
    CONFIG_ARG="--config=$GITHUB_WORKSPACE/$KNIP_CONFIG"
  else
    CONFIG_ARG="--config=$RUNNER_TEMP/.knip.json --no-config-hints"
  fi

  # Run knip with JSON output
  set +e
  DOTENV_CONFIG_QUIET=true knip --dependencies --exports --reporter json --no-progress "$CONFIG_ARG" > knip-output.json
  set -e

  # Reporting logic summarized here...
  # (In a real run, this would include the Node.js parsing blocks from original)
  
  popd
  echo "::endgroup::"
fi
