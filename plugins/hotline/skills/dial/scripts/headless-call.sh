#!/usr/bin/env bash
# =============================================================================
# Headless Call: Send a prompt to a workspace via claude -p
#
# First contact: claude -p with --output-format json, extracts session_id
# Follow-up: uses --resume with existing session ID
#
# Usage:
#   headless-call.sh --cwd <path> --prompt <text> [--resume <session-id>]
#
# Outputs JSON: {"session_id": "...", "response": "..."}
# On error: {"error": "..."} on stdout, exit 1
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: headless-call.sh --cwd <path> --prompt <text> [--resume <session-id>]"
  echo ""
  echo "Sends a prompt to a workspace via claude -p."
  echo "Outputs JSON: {\"session_id\": \"...\", \"response\": \"...\"}"
  exit 0
fi

CWD=""
PROMPT=""
RESUME_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No prompt provided"}'
  exit 1
fi

STDERR_FILE=$(mktemp)
trap "rm -f $STDERR_FILE" EXIT

if [[ -n "$RESUME_ID" ]]; then
  # Follow-up: --resume still needs to run from the target workspace
  # because Claude Code looks for sessions relative to the project directory
  if [[ -n "$CWD" ]]; then
    RESULT=$(cd "$CWD" && claude -p "$PROMPT" --resume "$RESUME_ID" --output-format json 2>"$STDERR_FILE") || true
  else
    RESULT=$(claude -p "$PROMPT" --resume "$RESUME_ID" --output-format json 2>"$STDERR_FILE") || true
  fi
else
  # First contact: cd to the target workspace before invoking claude
  if [[ -z "$CWD" ]]; then
    echo '{"error": "No --cwd provided for first contact"}'
    exit 1
  fi
  RESULT=$(cd "$CWD" && claude -p "$PROMPT" --output-format json 2>"$STDERR_FILE") || true
fi

if [[ -z "$RESULT" ]]; then
  STDERR_MSG=$(cat "$STDERR_FILE")
  jq -n --arg err "${STDERR_MSG:-Claude CLI returned no output}" '{error: $err}'
  exit 1
fi

SESSION_ID=$(echo "$RESULT" | jq -r '.session_id // empty')
RESPONSE=$(echo "$RESULT" | jq -r '.result // empty')

jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
  '{session_id: $sid, response: $resp}'
