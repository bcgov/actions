#!/bin/bash
set -euo pipefail

# Helper functions for consistency across all actions
function log_debug() {
  [ "${INPUT_DEBUG}" == "true" ] && echo "DEBUG: $1" || true
}

# Add your logic here!
log_debug "Action started: $(basename "$0")"

# To set an output:
# echo "my_output=val" >> "$GITHUB_OUTPUT"
