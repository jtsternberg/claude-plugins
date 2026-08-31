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
  echo "Usage: headless-call.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork-session] [--tools <tools>]"
  echo ""
  echo "Sends a prompt to a workspace via claude -p. Outputs two JSON lines:"
  echo "  Line 1 (immediate): {\"session_id\": \"...\"}"
  echo "  Line 2 (on complete): {\"session_id\": \"...\", \"response\": \"...\"}"
  echo ""
  echo "  --tools <tools>  Override allowed tools (default: \"Bash Read Edit Write Grep Glob\")"
  exit 0
fi

CWD=""
PROMPT=""
PROMPT_FILE=""
RESUME_ID=""
SESSION_NAME=""
FORK_SESSION=false
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    --name) SESSION_NAME="$2"; shift 2 ;;
    --fork-session) FORK_SESSION=true; shift ;;
    --tools) ALLOWED_TOOLS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# --prompt-file is preferred. `claude -p` reads its prompt from STDIN when given no
# positional prompt (verified live against claude 2.1.226 with
# --output-format stream-json), which keeps the payload out of an argv `ps`
# publishes to every local user (claude-plugins-86ka).
if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    jq -nc --arg p "$PROMPT_FILE" '{error: ("--prompt-file does not exist: " + $p)}'
    exit 1
  fi
  PROMPT=$(cat "$PROMPT_FILE")
fi

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No prompt provided"}'
  exit 1
fi

# Build the command as an array. NO positional prompt — it arrives on stdin.
CMD=(claude -p --allowedTools $ALLOWED_TOOLS --output-format stream-json --verbose)
[[ -n "${HOTLINE_CLAUDE_MODEL:-}" ]] && CMD+=(--model "$HOTLINE_CLAUDE_MODEL")
# Callee system-prompt override. The FILE form, never the raw
# --append-system-prompt string: a multi-line prompt on argv is readable via
# `ps`, the same leak the work-order payload is kept off argv to avoid.
[[ -n "${HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE:-}" ]] && \
  CMD+=(--append-system-prompt-file "$HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE")

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
# The prompt reaches claude on stdin, so it needs a file. 0600 before a byte of it
# is written — a default-umask copy of a work order in /tmp is readable by any
# local user, which is the whole reason it is not on the argv either.
STDIN_PROMPT=$(mktemp /tmp/hotline-headless-prompt-XXXXX)
chmod 600 "$STDIN_PROMPT"
printf '%s' "$PROMPT" > "$STDIN_PROMPT"
trap 'rm -f "$STDERR_FILE" "$STREAM_FILE" "$SID_FILE" "$STDIN_PROMPT"' EXIT

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
  (cd "$EXEC_DIR" && "${CMD[@]}" <"$STDIN_PROMPT" 2>"$STDERR_FILE") | stream_process || true
else
  "${CMD[@]}" <"$STDIN_PROMPT" 2>"$STDERR_FILE" | stream_process || true
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
