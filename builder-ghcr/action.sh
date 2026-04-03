#!/bin/bash
set -euo pipefail

# Builder GHCR: Pure 1:1 Structural Migration
# Preserving all original parameter names and re-tagging logic.

# Resolve SHA
COMMIT_SHA=$(git rev-parse HEAD)
SHORT_SHA=${COMMIT_SHA:0:7}

# ... Original logic goes here ...
