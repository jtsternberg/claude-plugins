#!/usr/bin/env bash
# =============================================================================
# Session Init: Orchestrate the two-step session ID discovery
#
# Wraps session-fingerprint.sh and session-discover.sh into a single helper
# that tells the agent exactly what to do next.
#
# IMPORTANT: The two steps MUST be separate tool calls because the transcript
# must be written (after the first tool call returns) before the fingerprint
# can be found in it. This script does NOT combine them into one step.
#
# Usage:
#   session-init.sh discover <fingerprint>   # Step 2: find session from fingerprint
#   session-init.sh                           # Step 1: check cache or plant fingerprint
#   session-init.sh --help
#
# Step 1 output (JSON on stdout):
#   {"status": "cached", "session_id": "..."}        — done, use this ID
#   {"status": "planted", "fingerprint": "..."}       — run step 2 in next tool call
#   {"status": "error", "message": "..."}             — something went wrong
#
# Step 2 output (JSON on stdout):
#   {"status": "discovered", "session_id": "..."}     — done, use this ID
#   {"status": "error", "message": "..."}             — discovery failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: session-init.sh                    # Check cache or plant fingerprint"
  echo "       session-init.sh discover <fp>      # Discover session from fingerprint"
  echo ""
  echo "Two-step session ID discovery orchestrator."
  echo "Step 1 and Step 2 MUST be separate tool calls."
  exit 0
fi

# Step 2: discover from fingerprint
if [[ "${1:-}" == "discover" ]]; then
  FINGERPRINT="${2:-}"
  if [[ -z "$FINGERPRINT" ]]; then
    echo '{"status":"error","message":"No fingerprint provided. Usage: session-init.sh discover <fingerprint>"}'
    exit 1
  fi

  RESULT=$("$SCRIPT_DIR/session-discover.sh" "$FINGERPRINT" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

  if [[ $EXIT_CODE -eq 0 ]]; then
    jq -n --arg sid "$RESULT" '{"status":"discovered","session_id":$sid}'
  else
    jq -n --arg msg "$RESULT" '{"status":"error","message":$msg}'
    exit 1
  fi
  exit 0
fi

# Step 1: check cache or plant fingerprint
STDERR_FILE=$(mktemp)
trap "rm -f $STDERR_FILE" EXIT

RESULT=$("$SCRIPT_DIR/session-fingerprint.sh" 2>"$STDERR_FILE") && EXIT_CODE=0 || EXIT_CODE=$?

case $EXIT_CODE in
  0)
    # Cache hit
    jq -n --arg sid "$RESULT" '{"status":"cached","session_id":$sid}'
    ;;
  1)
    # Cache miss — fingerprint planted
    FINGERPRINT=$(cat "$STDERR_FILE")
    jq -n --arg fp "$FINGERPRINT" '{"status":"planted","fingerprint":$fp,"next":"Run session-init.sh discover <fingerprint> in a SEPARATE tool call"}'
    ;;
  *)
    # Error (e.g., no claude process found)
    ERRMSG=$(cat "$STDERR_FILE")
    jq -n --arg msg "$ERRMSG" '{"status":"error","message":$msg}'
    exit 1
    ;;
esac
