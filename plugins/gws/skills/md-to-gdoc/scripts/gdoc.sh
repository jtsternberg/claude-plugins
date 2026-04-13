#!/usr/bin/env bash
# Upload or update a Google Doc from a markdown file.
# Auto-detects create vs update based on the destination argument.
#
# Usage:
#   gdoc.sh <markdown-file> <folder-id-or-doc-url> [--title "Custom Title"]
#
# If the destination contains "docs.google.com" or "document/d/", it's an update.
# Otherwise, it's a create into that folder.
#
# Output: Google Doc URL on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $# -lt 2 ]] && {
  echo "Usage: $(basename "$0") <markdown-file> <folder-id-or-doc-url> [--title \"Title\"]" >&2
  exit 1
}

DEST="$2"

if [[ "$DEST" == *"docs.google.com"* ]] || [[ "$DEST" == *"document/d/"* ]]; then
  # Update: pass file and doc ID/URL
  exec "$SCRIPT_DIR/update.sh" "$@"
else
  # Create: pass file, folder ID, and any extra flags (--title, etc.)
  exec "$SCRIPT_DIR/upload.sh" "$@"
fi
