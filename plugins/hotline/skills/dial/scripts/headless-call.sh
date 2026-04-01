#!/usr/bin/env bash
# =============================================================================
# Headless Call: Send a prompt to a workspace via claude -p
#
# First contact: claude -p with stream-json output, extracts session_id + result
# Follow-up: uses --resume with existing session ID
#
# Usage:
#   headless-call.sh --cwd <path> --prompt <text> [--resume <session-id>] [--name <name>] [--fork]
#
# Outputs JSON: {"session_id": "...", "response": "..."}
# On error: {"error": "..."} on stdout, exit 1
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: headless-call.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork]"
  echo ""
  echo "Sends a prompt to a workspace via claude -p. Uses stream-json for reliable output."
  echo "Outputs JSON: {\"session_id\": \"...\", \"response\": \"...\"}"
  exit 0
fi

CWD=""
PROMPT=""
RESUME_ID=""
SESSION_NAME=""
FORK_SESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    --name) SESSION_NAME="$2"; shift 2 ;;
    --fork) FORK_SESSION=true; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No prompt provided"}'
  exit 1
fi

# Build the command as an array to avoid the if/else branch explosion
CMD=(claude -p "$PROMPT" --allowedTools Bash --output-format stream-json --verbose)

if [[ -n "$RESUME_ID" ]]; then
  CMD+=(--resume "$RESUME_ID")
fi

if [[ -n "$SESSION_NAME" ]]; then
  CMD+=(-n "$SESSION_NAME")
fi

if $FORK_SESSION; then
  CMD+=(--fork-session)
fi

# Determine working directory
if [[ -n "$CWD" ]]; then
  EXEC_DIR="$CWD"
elif [[ -n "$RESUME_ID" ]]; then
  # Resume without cwd — run from current directory
  EXEC_DIR=""
else
  echo '{"error": "No --cwd provided for first contact"}'
  exit 1
fi

# Execute and capture the stream
STDERR_FILE=$(mktemp)
STREAM_FILE=$(mktemp)
trap "rm -f $STDERR_FILE $STREAM_FILE" EXIT

if [[ -n "$EXEC_DIR" ]]; then
  (cd "$EXEC_DIR" && "${CMD[@]}" 2>"$STDERR_FILE") > "$STREAM_FILE" || true
else
  "${CMD[@]}" 2>"$STDERR_FILE" > "$STREAM_FILE" || true
fi

# Parse the result event for session_id and metadata
RESULT_LINE=$(grep '"type":"result"' "$STREAM_FILE" | tail -1)

if [[ -z "$RESULT_LINE" ]]; then
  STDERR_MSG=$(cat "$STDERR_FILE")
  jq -n --arg err "${STDERR_MSG:-Claude CLI returned no output and no result event in stream}" '{error: $err}'
  exit 1
fi

SESSION_ID=$(echo "$RESULT_LINE" | jq -r '.session_id // empty')
RESPONSE=$(echo "$RESULT_LINE" | jq -r '.result // empty')

# If result field is empty, extract the last assistant text message from the stream.
# This handles the case where the agent's final action was a tool call (e.g., logging)
# but it DID produce a text response earlier in the conversation.
if [[ -z "$RESPONSE" ]]; then
  RESPONSE=$(grep '"type":"assistant"' "$STREAM_FILE" \
    | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | tail -1)
fi

# Still empty after scanning all assistant messages — warn the user
if [[ -z "$RESPONSE" ]]; then
  NUM_TURNS=$(echo "$RESULT_LINE" | jq -r '.num_turns // 0')
  RESPONSE="[HOTLINE WARNING: Agent ran $NUM_TURNS turns but produced no text response. Session ID: $SESSION_ID — resume manually to check what happened.]"
fi

jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
  '{session_id: $sid, response: $resp}'
