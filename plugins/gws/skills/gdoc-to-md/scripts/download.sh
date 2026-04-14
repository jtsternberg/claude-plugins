#!/usr/bin/env bash
# Download a Google Doc as a local markdown file.
# Uses native text/markdown export from the Google Drive API.
# Usage: download.sh <doc-id-or-url> [output.md] [--title]
# Output: Path to the created markdown file on stdout. Errors on stderr.
set -euo pipefail

# Resolve active account config directory
if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
  _COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/account-common.sh"
  if [[ -f "$_COMMON" ]]; then
    source "$_COMMON"
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
  fi
fi

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

# Fetch doc title from Drive metadata
DOC_TITLE=$(gws drive files get --params "{\"fileId\": \"$DOC_ID\", \"fields\": \"name\"}" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null || true)

if [[ -z "$DOC_TITLE" ]]; then
  bash "$(dirname "$0")/../../../scripts/diagnose-access.sh" "$DOC_ID" >&2
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

# Export directly as markdown via the Drive API's native text/markdown support
gws drive files export \
  --params "{\"fileId\": \"$DOC_ID\", \"mimeType\": \"text/markdown\"}" \
  --output "$OUTPUT" 2>&1

if [[ ! -s "$OUTPUT" ]]; then
  echo "ERROR: Export produced empty file. The document may be empty or export failed." >&2
  exit 1
fi

echo "$OUTPUT"
