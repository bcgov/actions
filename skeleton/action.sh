#!/bin/bash
set -euo pipefail

# Helper functions for consistency across all actions
function log_debug() {
  if [ "${INPUT_DEBUG}" == "true" ]; then
    echo "DEBUG: $1"
  fi
}

# Add your logic here!
log_debug "Action started: $(basename "$0")"

# To set an output:
# echo "my_output=val" >> "$GITHUB_OUTPUT"
