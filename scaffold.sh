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

# Find and replace placeholders
# Use | as sed delimiter to handle potential special chars in description
sed -i "s|__ACTION_NAME__|$NAME|g" "$NAME/action.yml"
sed -i "s|__ACTION_DESCRIPTION__|$DESCRIPTION|g" "$NAME/action.yml"

# Create a basic README.md
cat <<EOF > "$NAME/README.md"
# $NAME

$DESCRIPTION

## Usage

\`\`\`yaml
- uses: bcgov/actions/$NAME@v1
  with:
    token: \${{ secrets.GITHUB_TOKEN }}
\`\`\`

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| \`token\` | GitHub token | \`\${{ github.token }}\` |
| \`debug\` | Enable debug logging | \`false\` |
EOF

echo "Done! 🎉 Action created in $NAME/"
