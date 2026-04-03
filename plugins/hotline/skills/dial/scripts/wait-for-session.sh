#!/usr/bin/env bash
# =============================================================================
# Wait for Session: Poll until the remote session ID is available
#
# Polls call_dir/session_id.txt at 1s intervals until it appears.
# Prints the session ID to stdout on success.
#
# Exit codes:
#   0 — session ID found (printed to stdout)
#   1 — error (timeout, missing call_dir, or early failure)
#
# Usage:
#   wait-for-session.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

CALL_DIR="${1:-}"
TIMEOUT=30

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo '{"error":"Call directory not provided or does not exist"}' >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

ELAPSED=0
while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
  # Check if call already errored out
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    MSG=$(cat "$CALL_DIR/error.txt")
    echo "$MSG" >&2
    exit 1
  fi
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timed out waiting for session ID (${TIMEOUT}s)" >&2
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

cat "$CALL_DIR/session_id.txt"
