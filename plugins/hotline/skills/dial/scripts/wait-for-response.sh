#!/usr/bin/env bash
# =============================================================================
# Wait for Response: Poll until an async hotline call completes
#
# Polls call_dir/done at 2s intervals. On completion, prints the response
# JSON to stdout or the error message to stderr.
#
# Output (stdout):
#   {"session_id":"...","response":"..."}
#
# Exit codes:
#   0 — response received (JSON on stdout)
#   1 — error (timeout or remote failure; message on stderr)
#
# Usage:
#   wait-for-response.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

CALL_DIR="${1:-}"
TIMEOUT=300
POLL_INTERVAL=2

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo "Call directory not provided or does not exist" >&2
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
while [[ ! -f "$CALL_DIR/done" ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timed out waiting for response (${TIMEOUT}s)" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ -f "$CALL_DIR/error.txt" ]]; then
  cat "$CALL_DIR/error.txt" >&2
  exit 1
fi

if [[ -f "$CALL_DIR/response.json" ]]; then
  cat "$CALL_DIR/response.json"
else
  echo "Done but no response.json found" >&2
  exit 1
fi
