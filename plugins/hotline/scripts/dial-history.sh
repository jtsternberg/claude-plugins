#!/usr/bin/env bash
# =============================================================================
# Dial History: Append-only log of incoming calls per workspace
#
# Stored as JSONL at ~/.agents-hotline/identities/<hash>.dial_history.jsonl
# Capped at 100 entries — trims oldest on each write.
#
# Usage:
#   dial-history.sh append --cwd <path> --session <id> --caller <path> --mode <mode>
#   dial-history.sh read [--cwd <path>]
# =============================================================================
set -euo pipefail

IDENTITIES_DIR="$HOME/.agents-hotline/identities"
MAX_ENTRIES=100

CMD="${1:-}"
shift || true

CWD="$(pwd)"
SESSION_ID=""
CALLER=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --caller) CALLER="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CANONICAL=$(realpath "$CWD" 2>/dev/null || echo "$CWD")
PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
HISTORY_FILE="${IDENTITIES_DIR}/${PATH_HASH}.dial_history.jsonl"

mkdir -p "$IDENTITIES_DIR"

case "$CMD" in
  append)
    if [[ -z "$SESSION_ID" || -z "$CALLER" || -z "$MODE" ]]; then
      echo "Usage: dial-history.sh append --session <id> --caller <path> --mode <mode>" >&2
      exit 1
    fi
    NOW=$(date +%s)
    ENTRY=$(jq -n --arg s "$SESSION_ID" --arg c "$CALLER" --arg m "$MODE" --argjson t "$NOW" \
      '{session_id: $s, caller: $c, mode: $m, timestamp: $t}')
    echo "$ENTRY" >> "$HISTORY_FILE"

    # Trim to MAX_ENTRIES
    LINE_COUNT=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
    if [[ "$LINE_COUNT" -gt "$MAX_ENTRIES" ]]; then
      tail -n "$MAX_ENTRIES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
      mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    fi
    ;;
  read)
    if [[ -f "$HISTORY_FILE" ]]; then
      cat "$HISTORY_FILE"
    fi
    ;;
  *)
    echo "Usage: dial-history.sh <append|read> [options]" >&2
    exit 1
    ;;
esac
