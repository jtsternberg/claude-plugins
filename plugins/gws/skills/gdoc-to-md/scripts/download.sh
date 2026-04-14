#!/usr/bin/env bash
# Download a Google Doc as a local markdown file.
# Usage: download.sh <doc-id-or-url> [output.md] [--title]
# Output: Path to the created markdown file on stdout. Errors on stderr.
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <doc-id-or-url> [output.md] [--title]" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage

DOC_ID_OR_URL="$1"
shift

OUTPUT=""
USE_TITLE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) USE_TITLE=true; shift ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) OUTPUT="$1"; shift ;;
  esac
done

# Extract doc ID from URL if needed
# URL format: https://docs.google.com/document/d/DOC_ID/edit
if [[ "$DOC_ID_OR_URL" == *"docs.google.com"* ]] || [[ "$DOC_ID_OR_URL" == *"document/d/"* ]]; then
  DOC_ID=$(echo "$DOC_ID_OR_URL" | sed -E 's|.*/d/([^/]+).*|\1|')
else
  DOC_ID="$DOC_ID_OR_URL"
fi

# Check gws auth
if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
fi

# Check html-to-markdown
if ! command -v html-to-markdown >/dev/null 2>&1; then
  echo "ERROR: html-to-markdown not found in PATH" >&2
  exit 1
fi

# Fetch doc title from Drive metadata
DOC_TITLE=$(gws drive files get --params "{\"fileId\": \"$DOC_ID\", \"fields\": \"name\"}" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null || true)

if [[ -z "$DOC_TITLE" ]]; then
  echo "ERROR: Could not fetch document metadata. Check the doc ID and permissions." >&2
  exit 1
fi

echo "Downloading: $DOC_TITLE" >&2

# Determine output filename
if [[ -z "$OUTPUT" ]]; then
  if [[ "$USE_TITLE" == true ]]; then
    # Derive filename from doc title: lowercase, spaces to hyphens, strip non-alphanumeric
    OUTPUT=$(echo "$DOC_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9._-]//g')
    OUTPUT="${OUTPUT}.md"
  else
    OUTPUT="${DOC_ID}.md"
  fi
fi

# Export as HTML to a temp file
TMPHTML=$(mktemp "./__tmp-export-XXXXX.html")
trap 'rm -f "$TMPHTML"' EXIT

gws drive files export \
  --params "{\"fileId\": \"$DOC_ID\", \"mimeType\": \"text/html\"}" \
  --output "$TMPHTML" 2>&1

if [[ ! -s "$TMPHTML" ]]; then
  echo "ERROR: Export produced empty file. The document may be empty or export failed." >&2
  exit 1
fi

# Convert HTML to Markdown
html-to-markdown "$TMPHTML" "$OUTPUT"

if [[ ! -f "$OUTPUT" ]]; then
  echo "ERROR: Markdown conversion failed." >&2
  exit 1
fi

echo "$OUTPUT"
