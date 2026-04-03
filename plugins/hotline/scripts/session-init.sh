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
#   session-init.sh [--expanded]                           # Step 1: check cache or plant fingerprint
#   session-init.sh discover <fingerprint> [--expanded]    # Step 2: find session from fingerprint
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
#
# With --expanded, "cached" and "discovered" responses also include:
#   "transcript_path", "claude_pid", "project_dir"
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: session-init.sh [--expanded]                    # Check cache or plant fingerprint"
  echo "       session-init.sh discover <fp> [--expanded]      # Discover session from fingerprint"
  echo ""
  echo "Two-step session ID discovery orchestrator."
  echo "Step 1 and Step 2 MUST be separate tool calls."
  echo ""
  echo "Options:"
  echo "  --expanded  Include transcript_path, claude_pid, project_dir in JSON output"
  exit 0
fi

# Parse all args — flags can appear anywhere
EXPANDED=false
SUBCOMMAND=""
FINGERPRINT=""
for arg in "$@"; do
  case "$arg" in
    --expanded) EXPANDED=true ;;
    discover) SUBCOMMAND="discover" ;;
    *) FINGERPRINT="$arg" ;;
  esac
done

# Step 2: discover from fingerprint
if [[ "$SUBCOMMAND" == "discover" ]]; then
  if [[ -z "$FINGERPRINT" ]]; then
    echo '{"status":"error","message":"No fingerprint provided. Usage: session-init.sh discover <fingerprint>"}'
    exit 1
  fi

  if [[ "$EXPANDED" == true ]]; then
    RESULT=$("$SCRIPT_DIR/session-discover.sh" "$FINGERPRINT" --json 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
      echo "$RESULT" | jq '{status: "discovered"} + .'
    else
      jq -n --arg msg "$RESULT" '{"status":"error","message":$msg}'
      exit 1
    fi
  else
    RESULT=$("$SCRIPT_DIR/session-discover.sh" "$FINGERPRINT" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
      jq -n --arg sid "$RESULT" '{"status":"discovered","session_id":$sid}'
    else
      jq -n --arg msg "$RESULT" '{"status":"error","message":$msg}'
      exit 1
    fi
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
    if [[ "$EXPANDED" == true ]]; then
      # Look up cached transcript path, or reconstruct it
      CLAUDE_PID=""
      cpid=$$
      while [[ "$cpid" != "1" && -n "$cpid" ]]; do
        comm=$(ps -o comm= -p "$cpid" 2>/dev/null | xargs)
        if [[ "$comm" == "claude" ]]; then
          CLAUDE_PID="$cpid"
          break
        fi
        cpid=$(ps -o ppid= -p "$cpid" 2>/dev/null | tr -d ' ')
      done

      TRANSCRIPT_CACHE="/tmp/claude-session-${CLAUDE_PID}.transcript"
      if [[ -n "$CLAUDE_PID" && -f "$TRANSCRIPT_CACHE" ]]; then
        TRANSCRIPT_PATH=$(cat "$TRANSCRIPT_CACHE")
      else
        # Reconstruct from convention
        PROJECT_HASH=$(pwd | sed 's|[^a-zA-Z0-9-]|-|g')
        TRANSCRIPT_PATH="$HOME/.claude/projects/${PROJECT_HASH}/${RESULT}.jsonl"
      fi
      PROJECT_DIR=$(dirname "$TRANSCRIPT_PATH")
      jq -n --arg sid "$RESULT" --arg path "$TRANSCRIPT_PATH" --arg pid "${CLAUDE_PID:-}" --arg dir "$PROJECT_DIR" \
        '{"status":"cached","session_id":$sid,"transcript_path":$path,"claude_pid":$pid,"project_dir":$dir}'
    else
      jq -n --arg sid "$RESULT" '{"status":"cached","session_id":$sid}'
    fi
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
