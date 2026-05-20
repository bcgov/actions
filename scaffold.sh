#!/bin/bash
set -euo pipefail

NAME="${1:-}"
DESCRIPTION="${2:-A cool new action. Please add a description!}"

if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <action-name> [description]"
  exit 1
fi

if [[ -d "$NAME" ]]; then
  echo "Error: Directory '$NAME' already exists."
  exit 1
fi

echo "Scaffolding action: $NAME..."

# Create directory and copy skeleton
mkdir -p "$NAME"
cp skeleton/action.yml "$NAME/action.yml"
cp skeleton/action.sh "$NAME/action.sh"
chmod +x "$NAME/action.sh"

# Find and replace placeholders using Python for safety and portability
ACTION_YML="$NAME/action.yml" ACTION_NAME="$NAME" ACTION_DESCRIPTION="$DESCRIPTION" python3 - <<'PY'
import os
from pathlib import Path

action_yml = Path(os.environ["ACTION_YML"])
content = action_yml.read_text(encoding="utf-8")
content = content.replace("__ACTION_NAME__", os.environ["ACTION_NAME"])
content = content.replace("__ACTION_DESCRIPTION__", os.environ["ACTION_DESCRIPTION"])
action_yml.write_text(content, encoding="utf-8")
PY

# Create a basic README.md
cat <<EOF > "$NAME/README.md"
# $NAME

$DESCRIPTION

## Usage

\`\`\`yaml
- uses: bcgov/actions/$NAME@v1
  with:
    github_token: \${{ secrets.GITHUB_TOKEN }}
\`\`\`

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| \`github_token\` | GitHub token | \`\${{ github.token }}\` |
| \`debug\` | Enable debug logging | \`false\` |
EOF

echo "Done! 🎉 Action created in $NAME/"
