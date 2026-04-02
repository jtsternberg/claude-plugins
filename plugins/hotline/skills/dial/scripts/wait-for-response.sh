#!/usr/bin/env bash
# =============================================================================
# Wait for Response: Poll an async hotline call until it completes
#
# Waits for session_id.txt to appear (quick poll), prints it to stdout,
# then waits for the done sentinel file and prints the response or error.
#
# Output (two-phase, both to stdout):
#   Phase 1: JSON  {"phase":"connected","session_id":"..."}
#   Phase 2: JSON  {"phase":"complete","session_id":"...","response":"..."}
#         or JSON  {"phase":"error","message":"..."}
#
# Exit codes:
#   0 — response received successfully
#   1 — error (timeout, missing call_dir, or remote failure)
#
# Usage:
#   wait-for-response.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

CALL_DIR="${1:-}"
TIMEOUT=300  # 5 minutes default
POLL_INTERVAL=2

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo '{"phase":"error","message":"Call directory not provided or does not exist"}'
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Phase 1: Wait for session ID (tight poll, 1s intervals, 30s max)
SID_TIMEOUT=30
SID_ELAPSED=0
while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
  if [[ $SID_ELAPSED -ge $SID_TIMEOUT ]]; then
    # Check if call already errored out
    if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
      MSG=$(cat "$CALL_DIR/error.txt")
      jq -n --arg msg "$MSG" '{"phase":"error","message":$msg}'
      exit 1
    fi
    jq -n '{"phase":"error","message":"Timed out waiting for session ID (30s)"}'
    exit 1
  fi
  sleep 1
  SID_ELAPSED=$((SID_ELAPSED + 1))
done

SESSION_ID=$(cat "$CALL_DIR/session_id.txt")
jq -n --arg sid "$SESSION_ID" '{"phase":"connected","session_id":$sid}'

# Phase 2: Wait for completion
ELAPSED=0
while [[ ! -f "$CALL_DIR/done" ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    jq -n --arg sid "$SESSION_ID" '{"phase":"error","message":"Timed out waiting for response","session_id":$sid}'
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Check for errors
if [[ -f "$CALL_DIR/error.txt" ]]; then
  MSG=$(cat "$CALL_DIR/error.txt")
  jq -n --arg msg "$MSG" --arg sid "$SESSION_ID" '{"phase":"error","message":$msg,"session_id":$sid}'
  exit 1
fi

# Return the response
if [[ -f "$CALL_DIR/response.json" ]]; then
  RESP=$(cat "$CALL_DIR/response.json")
  SESSION_ID=$(echo "$RESP" | jq -r '.session_id // empty')
  RESPONSE=$(echo "$RESP" | jq -r '.response // empty')
  jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
    '{"phase":"complete","session_id":$sid,"response":$resp}'
else
  jq -n --arg sid "$SESSION_ID" '{"phase":"error","message":"Done but no response.json found","session_id":$sid}'
  exit 1
fi
