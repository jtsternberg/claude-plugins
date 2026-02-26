#!/usr/bin/env bash
# Scaffold a new presentation from the template
set -euo pipefail

TITLE="${1:?Usage: new-presentation.sh <title> [output-dir]}"
OUT_DIR="${2:-.}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$SKILL_DIR/references/slide-template.html"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: Template not found at $TEMPLATE"
  exit 1
fi

mkdir -p "$OUT_DIR"
cp "$TEMPLATE" "$OUT_DIR/presentation.html"

# Replace title placeholder; leave subtitle/tagline for manual editing
sed -i '' "s/{{TITLE}}/$TITLE/g" "$OUT_DIR/presentation.html"

echo "Created $OUT_DIR/presentation.html from template"
echo "Next: replace {{SUBTITLE}} and {{TAGLINE}}, then add your slides."
