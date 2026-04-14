#!/usr/bin/env bash
# Update an existing Google Doc from a markdown file.
# Usage: update.sh <markdown-file> <doc-id-or-url>
# Output: Google Doc URL on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: $(basename "$0") <markdown-file> <doc-id-or-url>" >&2
  exit 1
}

[[ $# -lt 2 ]] && usage

FILE="$1"
DOC_ID_OR_URL="$2"

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE" >&2
  exit 1
fi

# Check gws auth
if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
fi

# Extract doc ID from URL if needed
# URL format: https://docs.google.com/document/d/DOC_ID/edit
if [[ "$DOC_ID_OR_URL" == *"docs.google.com"* ]]; then
  DOC_ID=$(echo "$DOC_ID_OR_URL" | sed -E 's|.*/d/([^/]+).*|\1|')
else
  DOC_ID="$DOC_ID_OR_URL"
fi

# Clean: strip YAML frontmatter and Obsidian callout headers
CLEAN=$(mktemp "./__tmp-update-XXXXX.md")
trap 'rm -f "$CLEAN"' EXIT

"$SCRIPT_DIR/clean.sh" "$FILE" "$CLEAN"

# Update — gws requires relative paths within cwd
RESPONSE=$(gws drive files update \
  --params "{\"fileId\": \"$DOC_ID\"}" \
  --upload "$CLEAN" \
  --upload-content-type text/markdown 2>&1)

# Verify response has the doc ID
RETURNED_ID=$(printf '%s' "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

if [[ -z "$RETURNED_ID" ]]; then
  bash "$SCRIPT_DIR/../../../scripts/diagnose-access.sh" "$DOC_ID" >&2
  exit 1
fi

echo "https://docs.google.com/document/d/$DOC_ID/edit"
