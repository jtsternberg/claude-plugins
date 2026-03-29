#!/usr/bin/env bash
# =============================================================================
# Minimal dirmap fallback — used when full dirmap is not in PATH
#
# Only supports: get <id>, list
# Reads from ~/.dirmap.json (same format as full dirmap tool)
#
# Usage:
#   dirmap-fallback.sh get <id>    # Print path for project ID
#   dirmap-fallback.sh list        # Print all entries as JSON
# =============================================================================
set -euo pipefail

DIRMAP_FILE="$HOME/.dirmap.json"

if [[ ! -f "$DIRMAP_FILE" ]]; then
  echo "Error: $DIRMAP_FILE not found" >&2
  exit 1
fi

CMD="${1:-}"
case "$CMD" in
  get)
    ID="${2:-}"
    if [[ -z "$ID" ]]; then
      echo "Usage: dirmap-fallback.sh get <id>" >&2
      exit 1
    fi
    RESULT=$(jq -r --arg id "$ID" '.[$id] // empty' "$DIRMAP_FILE")
    if [[ -z "$RESULT" ]]; then
      echo "Error: No entry for '$ID'" >&2
      exit 1
    fi
    echo "$RESULT"
    ;;
  list)
    jq -r '.' "$DIRMAP_FILE"
    ;;
  *)
    echo "Usage: dirmap-fallback.sh <get|list> [id]" >&2
    exit 1
    ;;
esac
