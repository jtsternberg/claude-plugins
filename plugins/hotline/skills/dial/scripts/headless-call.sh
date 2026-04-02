#!/usr/bin/env bash
# =============================================================================
# Headless Call: Send a prompt to a workspace via claude -p
#
# First contact: claude -p with stream-json output, extracts session_id + result
# Follow-up: uses --resume with existing session ID
#
# Output: TWO lines of JSON:
#   Line 1 (immediate): {"session_id": "..."}
#   Line 2 (on completion): {"session_id": "...", "response": "..."}
#
# This lets the caller surface the session ID to the user before the
# remote agent finishes its work.
#
# On error: {"error": "..."} on stdout, exit 1
#
# Usage:
#   headless-call.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork-session]
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: headless-call.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork-session]"
  echo ""
  echo "Sends a prompt to a workspace via claude -p. Outputs two JSON lines:"
  echo "  Line 1 (immediate): {\"session_id\": \"...\"}"
  echo "  Line 2 (on complete): {\"session_id\": \"...\", \"response\": \"...\"}"
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
    --fork-session) FORK_SESSION=true; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No prompt provided"}'
  exit 1
fi

# Build the command as an array
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
  EXEC_DIR=""
else
  echo '{"error": "No --cwd provided for first contact"}'
  exit 1
fi

# Temp files
STDERR_FILE=$(mktemp)
STREAM_FILE=$(mktemp)
SID_FILE=$(mktemp)
trap "rm -f $STDERR_FILE $STREAM_FILE $SID_FILE" EXIT

# Stream processor: extracts session_id from first event that has one,
# writes it to SID_FILE and emits it immediately as line 1 of output.
# Tees all stream data to STREAM_FILE for later parsing.
stream_process() {
  local sid_emitted=false
  while IFS= read -r line; do
    echo "$line" >> "$STREAM_FILE"
    if ! $sid_emitted; then
      local sid
      sid=$(echo "$line" | jq -r '.session_id // empty' 2>/dev/null || true)
      if [[ -n "$sid" ]]; then
        echo "$sid" > "$SID_FILE"
        jq -n --arg sid "$sid" '{session_id: $sid}'
        sid_emitted=true
      fi
    fi
  done
}

# Execute and pipe through stream processor
if [[ -n "$EXEC_DIR" ]]; then
  (cd "$EXEC_DIR" && "${CMD[@]}" 2>"$STDERR_FILE") | stream_process || true
else
  "${CMD[@]}" 2>"$STDERR_FILE" | stream_process || true
fi

# Check for completely empty stream
if [[ ! -s "$STREAM_FILE" ]]; then
  STDERR_MSG=$(cat "$STDERR_FILE")
  jq -n --arg err "${STDERR_MSG:-Claude CLI produced no output at all. If using --fork-session, verify --cwd points to the TARGET session's workspace (use resolve-workspace.sh with the session ID), not the caller's workspace.}" '{error: $err}'
  exit 1
fi

# Parse the result event for final response
RESULT_LINE=$(grep '"type":"result"' "$STREAM_FILE" | tail -1)

if [[ -z "$RESULT_LINE" ]]; then
  STDERR_MSG=$(cat "$STDERR_FILE")
  jq -n --arg err "${STDERR_MSG:-Stream had data but no result event. The session may have been interrupted or timed out.}" '{error: $err}'
  exit 1
fi

SESSION_ID=$(echo "$RESULT_LINE" | jq -r '.session_id // empty')
RESPONSE=$(echo "$RESULT_LINE" | jq -r '.result // empty')

# If result field is empty, extract the last assistant text message from the stream
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

# Line 2: full response
jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
  '{session_id: $sid, response: $resp}'
