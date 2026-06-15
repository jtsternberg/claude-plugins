#!/usr/bin/env bash
# Upload or update a Google Doc from a markdown file.
# Auto-detects create vs update based on the destination argument.
#
# Usage:
#   gdoc.sh <markdown-file> <folder-id-or-url> [--title "Custom Title"]
#   gdoc.sh <markdown-file> --folder <folder-id-or-url> [--title "Custom Title"]
#   gdoc.sh <markdown-file> <doc-id-or-url>      # update existing doc
#
# If any argument looks like a Google Doc URL/path (docs.google.com/document
# or document/d/), it's an update. Otherwise it's a create into the given
# folder. Both the positional folder and the --folder flag accept a bare
# folder ID or a full Drive folder URL.
#
# Output: Google Doc URL on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $# -lt 1 ]] && {
  echo "Usage: $(basename "$0") <markdown-file> <folder-id-or-url|doc-id-or-url> [--title \"Title\"]" >&2
  echo "       $(basename "$0") <markdown-file> --folder <folder-id-or-url> [--title \"Title\"]" >&2
  exit 1
}

# Scan all args for a Google Doc destination → route to update.
# Folder URLs live on drive.google.com/.../folders/ and never match these,
# so the --folder flag and folder URLs always route to create.
for arg in "$@"; do
  if [[ "$arg" == *"docs.google.com/document"* ]] || [[ "$arg" == *"document/d/"* ]]; then
    exec "$SCRIPT_DIR/update.sh" "$@"
  fi
done

# Create: pass file, folder (positional or --folder), and any extra flags.
exec "$SCRIPT_DIR/upload.sh" "$@"
