#!/usr/bin/env bash
# Wrapper for get-pr that utilizes the consolidated image-tracker forensic engine.
# This ensures consistent PR resolution across all BC Gov actions.

set -euo pipefail

# Map inputs to image-tracker expected environment variables
export INPUT_TOKEN="${INPUT_TOKEN:-$GITHUB_TOKEN}"
export INPUT_PACKAGE=""
export INPUT_MAX_DEPTH=1
export INPUT_REVISION="${GITHUB_SHA:-HEAD}"
export INPUT_REPOSITORY="${GITHUB_REPOSITORY:-}"

# Determine the path to the shared engine
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_PATH="${SCRIPT_DIR}/../image-tracker/action.sh"

if [[ ! -f "$ENGINE_PATH" ]]; then
    echo "::error::Consolidated engine not found at $ENGINE_PATH"
    exit 1
fi

# Execute the engine
# Note: The engine writes its outputs (like 'pr') directly to $GITHUB_OUTPUT
bash "$ENGINE_PATH"
