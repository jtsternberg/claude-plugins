#!/usr/bin/env bash
# =============================================================================
# Session Cache: Track Agent A's outgoing connections
#
# Stores session maps in ~/.agents-hotline/sessions/<caller-session>.json
# Keyed by Agent A's session ID to prevent collisions.
#
# Usage:
#   session-cache.sh get <target-path> --caller-session <id>
#   session-cache.sh set <target-path> --caller-session <id> --session <id> --mode <mode>
#   session-cache.sh update <target-path> --caller-session <id>
#   session-cache.sh list --caller-session <id>
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: session-cache.sh get <target-path> --caller-session <id>"
  echo "       session-cache.sh set <target-path> --caller-session <id> --session <id> --mode <mode>"
  echo "       session-cache.sh update <target-path> --caller-session <id>"
  echo "       session-cache.sh list --caller-session <id>"
  echo ""
  echo "Tracks Agent A's outgoing connections in ~/.agents-hotline/sessions/<caller-session>.json"
  exit 0
fi

SESSIONS_DIR="$HOME/.agents-hotline/sessions"
mkdir -p "$SESSIONS_DIR"

CMD="${1:-}"
shift || true

# Parse flags
TARGET=""
CALLER_SESSION=""
SESSION_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="$2"; shift 2 ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) [[ -z "$TARGET" ]] && TARGET="$1"; shift ;;
  esac
done

if [[ -z "$CALLER_SESSION" ]]; then
  echo "Error: --caller-session required" >&2
  exit 1
fi

CACHE_FILE="${SESSIONS_DIR}/${CALLER_SESSION}.json"

# Resolve target to canonical path
if [[ -n "$TARGET" ]]; then
  TARGET=$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")
fi

case "$CMD" in
  get)
    if [[ -z "$TARGET" ]]; then
      echo "Usage: session-cache.sh get <target-path> --caller-session <id>" >&2
      exit 1
    fi
    if [[ ! -f "$CACHE_FILE" ]]; then
      exit 1
    fi
    RESULT=$(jq -r --arg t "$TARGET" '.connections[$t] // empty' "$CACHE_FILE")
    if [[ -z "$RESULT" ]]; then
      exit 1
    fi
    echo "$RESULT"
    ;;
  set)
    if [[ -z "$TARGET" || -z "$SESSION_ID" || -z "$MODE" ]]; then
      echo "Usage: session-cache.sh set <target> --caller-session <id> --session <id> --mode <mode>" >&2
      exit 1
    fi
    NOW=$(date +%s)
    CALLER_CWD=$(realpath "$(pwd)" 2>/dev/null || pwd)
    if [[ -f "$CACHE_FILE" ]]; then
      jq --arg t "$TARGET" --arg s "$SESSION_ID" --arg m "$MODE" --argjson now "$NOW" \
        '.connections[$t] = {session_id: $s, started: $now, last_contact: $now, mode: $m, exchange_count: 1}' \
        "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    else
      jq -n --arg caller "$CALLER_CWD" --arg cs "$CALLER_SESSION" \
        --arg t "$TARGET" --arg s "$SESSION_ID" --arg m "$MODE" --argjson now "$NOW" \
        '{caller: $caller, caller_session_id: $cs, connections: {($t): {session_id: $s, started: $now, last_contact: $now, mode: $m, exchange_count: 1}}}' \
        > "$CACHE_FILE"
    fi
    ;;
  update)
    if [[ -z "$TARGET" || ! -f "$CACHE_FILE" ]]; then
      exit 1
    fi
    NOW=$(date +%s)
    jq --arg t "$TARGET" --argjson now "$NOW" \
      '.connections[$t].last_contact = $now | .connections[$t].exchange_count += 1' \
      "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    ;;
  list)
    if [[ -f "$CACHE_FILE" ]]; then
      cat "$CACHE_FILE"
    else
      echo "{}"
    fi
    ;;
  *)
    echo "Usage: session-cache.sh <get|set|update|list> [target] --caller-session <id>" >&2
    exit 1
    ;;
esac
