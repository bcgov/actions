#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v node &>/dev/null; then
  exec node --test "${SCRIPT_DIR}/unit.test.js"
elif command -v podman &>/dev/null; then
  exec podman run --rm -v "$(pwd):/app:z" -w /app node:24-alpine sh -c "command -v git &>/dev/null || apk add --no-cache git >/dev/null 2>&1; exec node --test image-tracker/tests/unit.test.js"
else
  echo "Error: Node.js runtime or podman container engine required to run unit tests." >&2
  exit 1
fi
