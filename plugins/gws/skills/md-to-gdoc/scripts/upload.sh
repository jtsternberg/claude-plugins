#!/usr/bin/env bash
# Upload a markdown file to Google Drive as a Google Doc.
# Usage: upload.sh <markdown-file> <folder-id> [--title "Custom Title"]
# Output: Google Doc URL on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve active account config directory
if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
  _COMMON="$SCRIPT_DIR/../../../scripts/account-common.sh"
  if [[ -f "$_COMMON" ]]; then
    source "$_COMMON"
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
  fi
fi

usage() {
  echo "Usage: $(basename "$0") <markdown-file> <folder-id> [--title \"Title\"]" >&2
  exit 1
}

[[ $# -lt 2 ]] && usage

FILE="$1"
FOLDER_ID="$2"
shift 2

TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE" >&2
  exit 1
fi

# Check gws auth
if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
fi

# Derive title if not provided
if [[ -z "$TITLE" ]]; then
  # Prefer H1 heading from file content (skip frontmatter first)
  TITLE=$(awk '
    BEGIN {skip=0}
    NR==1 && /^---$/ {skip=1; next}
    skip==1 && /^---$/ {skip=0; next}
    skip==0 && /^# / {sub(/^# /, ""); print; exit}
  ' "$FILE")
  # Fall back to filename
  if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$FILE" .md | tr '-' ' ')
  fi
fi

# Clean: strip YAML frontmatter and Obsidian callout headers
CLEAN=$(mktemp "./__tmp-upload-XXXXX.md")
trap 'rm -f "$CLEAN"' EXIT

"$SCRIPT_DIR/clean.sh" "$FILE" "$CLEAN"

# Upload — gws requires relative paths within cwd
RESPONSE=$(gws drive files create \
  --json "{\"name\": $(printf '%s' "$TITLE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"mimeType\": \"application/vnd.google-apps.document\", \"parents\": [\"$FOLDER_ID\"]}" \
  --upload "$CLEAN" \
  --upload-content-type text/markdown 2>&1)

DOC_ID=$(printf '%s' "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

if [[ -z "$DOC_ID" ]]; then
  bash "$SCRIPT_DIR/../../../scripts/diagnose-access.sh" "$FOLDER_ID" >&2
  exit 1
fi

# Set pageless format
gws docs documents batchUpdate \
  --params "{\"documentId\": \"$DOC_ID\"}" \
  --json '{"requests": [{"updateDocumentStyle": {"documentStyle": {"documentFormat": {"documentMode": "PAGELESS"}}, "fields": "documentFormat"}}]}' >/dev/null 2>&1

# Verify document exists
if ! gws drive files get --params "{\"fileId\": \"$DOC_ID\", \"fields\": \"id\"}" >/dev/null 2>&1; then
  echo "WARNING: Upload appeared to succeed but verification failed. Doc ID: $DOC_ID" >&2
fi

echo "https://docs.google.com/document/d/$DOC_ID/edit"
