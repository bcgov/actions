#!/usr/bin/env bash
set -euo pipefail

# test-and-analyse
# Orchestrates Node tests, SonarCloud analysis, and Knip dependency checks

echo "::group::Environment Information"
echo "Running Test & Analysis for component in: $DIR"
echo "Node version: $(node --version)"
echo "::endgroup::"

# 1. Supply Chain Protection
if [[ "$SUPPLY_SCAN" == "true" ]]; then
  if command -v safe-chain >/dev/null 2>&1; then
    echo "::group::Supply Chain Scan (Safe-Chain)"
    safe-chain setup-ci
    echo "::endgroup::"
  else
    echo "::warning::safe-chain not found; skipping supply chain scan."
  fi
fi

# 2. Run Tests
echo "::group::Running Component Tests"
pushd "$DIR"

# Determine package manager and run deterministic install based on user choice
case "$CACHE" in
  yarn) yarn install --frozen-lockfile ;;
  pnpm) pnpm install --frozen-lockfile ;;
  *)    npm ci ;;
esac

# Execute user commands with secure shell invocation (Upgrade from eval)
bash -lc "$COMMANDS"
popd
echo "::endgroup::"

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
  KNIP_RES=$?
  set -e

  # Process JSON with engine
  node "$GITHUB_ACTION_PATH/knip-reporter.js" "$(pwd)/knip-output.json"

  popd
  echo "::endgroup::"

  # Exit based on scan result if error mode enabled
  if [[ $KNIP_RES -ne 0 ]] && [[ "$DEP_SCAN" == "error" ]]; then
     echo "::error::Knip found dependency issues and dep_scan is set to error."
     exit $KNIP_RES
  fi
fi
