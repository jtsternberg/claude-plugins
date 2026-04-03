#!/usr/bin/env bash
# =============================================================================
# Headless Call (Async): Fire a headless call in the background
#
# Starts claude -p in the background, captures the session ID as soon as
# it appears in the stream, writes it to a known file, and continues
# collecting the full response.
#
# Output files (written to $HOTLINE_CALL_DIR or /tmp/hotline-call-<random>/):
#   session_id.txt  — written as soon as session ID appears in stream
#   response.json   — written when call completes: {"session_id":"..","response":".."}
#   error.txt       — written if the call fails
#   done            — empty sentinel file, created when call finishes
#
# Usage:
#   headless-call-async.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork-session]
#   # Returns immediately with: {"call_dir": "/tmp/hotline-call-xxxxx"}
#   # Then poll for done file and read response.json
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: headless-call-async.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork-session]"
  echo ""
  echo "Fires a headless call in the background. Returns immediately with the call_dir."
  echo "Session ID written to call_dir/session_id.txt as soon as available."
  echo "Full response written to call_dir/response.json when complete."
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

# Create call directory
CALL_DIR=$(mktemp -d /tmp/hotline-call-XXXXX)

# Build the command
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
  rm -rf "$CALL_DIR"
  exit 1
fi

# Background worker: runs the call, extracts session ID early, writes response
(
  STREAM_FILE="$CALL_DIR/stream.jsonl"
  STDERR_FILE="$CALL_DIR/stderr.txt"
  SID_WRITTEN=false

  # Run claude and process the stream
  if [[ -n "$EXEC_DIR" ]]; then
    (cd "$EXEC_DIR" && "${CMD[@]}" 2>"$STDERR_FILE") | while IFS= read -r line; do
      echo "$line" >> "$STREAM_FILE"
      if ! $SID_WRITTEN; then
        SID=$(echo "$line" | jq -r '.session_id // empty' 2>/dev/null || true)
        if [[ -n "$SID" ]]; then
          echo "$SID" > "$CALL_DIR/session_id.txt"
          SID_WRITTEN=true
        fi
      fi
    done || true
  else
    "${CMD[@]}" 2>"$STDERR_FILE" | while IFS= read -r line; do
      echo "$line" >> "$STREAM_FILE"
      if ! $SID_WRITTEN; then
        SID=$(echo "$line" | jq -r '.session_id // empty' 2>/dev/null || true)
        if [[ -n "$SID" ]]; then
          echo "$SID" > "$CALL_DIR/session_id.txt"
          SID_WRITTEN=true
        fi
      fi
    done || true
  fi

  # Parse final response
  if [[ ! -s "$STREAM_FILE" ]]; then
    STDERR_MSG=$(cat "$STDERR_FILE" 2>/dev/null || true)
    echo "${STDERR_MSG:-Claude CLI produced no output}" > "$CALL_DIR/error.txt"
    touch "$CALL_DIR/done"
    exit 0
  fi

  RESULT_LINE=$(grep '"type":"result"' "$STREAM_FILE" 2>/dev/null | tail -1 || true)

  if [[ -z "$RESULT_LINE" ]]; then
    STDERR_MSG=$(cat "$STDERR_FILE" 2>/dev/null || true)
    echo "${STDERR_MSG:-Stream had data but no result event}" > "$CALL_DIR/error.txt"
    touch "$CALL_DIR/done"
    exit 0
  fi

  SESSION_ID=$(echo "$RESULT_LINE" | jq -r '.session_id // empty')
  RESPONSE=$(echo "$RESULT_LINE" | jq -r '.result // empty')

  # Fallback: extract last assistant text if result is empty
  if [[ -z "$RESPONSE" ]]; then
    RESPONSE=$(grep '"type":"assistant"' "$STREAM_FILE" \
      | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null \
      | tail -1 || true)
  fi

  if [[ -z "$RESPONSE" ]]; then
    NUM_TURNS=$(echo "$RESULT_LINE" | jq -r '.num_turns // 0')
    RESPONSE="[HOTLINE WARNING: Agent ran $NUM_TURNS turns but produced no text response. Session ID: $SESSION_ID]"
  fi

  jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
    '{session_id: $sid, response: $resp}' > "$CALL_DIR/response.json"

  touch "$CALL_DIR/done"
) &>/dev/null &

# Return immediately with the call directory
jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
