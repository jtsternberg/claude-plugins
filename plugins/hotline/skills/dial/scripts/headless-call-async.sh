#!/usr/bin/env bash
# =============================================================================
# Headless Call (Async): Fire a headless call in the background
#
# Starts claude -p in the background, captures the session ID as soon as
# it appears in the stream, writes it to a known file, and continues
# collecting the full response.
#
# Output files (written under ${HOTLINE_CALL_HOME:-/tmp}/hotline-call-<random>/):
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
  echo "Usage: headless-call-async.sh --cwd <path> --prompt <text> [--resume <id>] [--name <name>] [--fork-session] [--tools <tools>]"
  echo ""
  echo "Fires a headless call in the background. Returns immediately with the call_dir."
  echo "Session ID written to call_dir/session_id.txt as soon as available."
  echo "Full response written to call_dir/response.json when complete."
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

# --prompt-file is preferred, and dial.sh always uses it. `claude -p` reads its
# prompt from STDIN when no positional prompt is given (verified live against
# claude 2.1.226 with --output-format stream-json), so the payload can reach the
# receiver without ever appearing in an argv that `ps` publishes to every local
# user (claude-plugins-86ka). --prompt is kept for direct callers and is written
# to a private temp file below rather than passed through.
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

# --fork-session COPIES the resumed session's transcript into a new id. With no
# --resume target there is nothing to copy, so claude forks an EMPTY session — the
# call appears to succeed but the receiver reports "fresh session, nothing run here".
# In hotline usage --fork-session is only ever valid alongside --resume, so refuse
# the combination instead of silently forking nothing.
if $FORK_SESSION && [[ -z "$RESUME_ID" ]]; then
  echo '{"error": "--fork-session requires --resume <id>; forking with no resume target silently creates an empty session"}'
  exit 1
fi

# Create call directory. HOTLINE_CALL_HOME overrides the base (default /tmp) so
# test suites can point every call dir at a directory they own and wipe on exit,
# instead of leaving hundreds of /tmp/hotline-call-* dirs behind (claude-plugins-cjgn).
# Production is unchanged: unset → /tmp.
CALL_DIR=$(mktemp -d "${HOTLINE_CALL_HOME:-/tmp}/hotline-call-XXXXX")
# Which backend owns this call dir. Headless places no host, so it writes no host
# handle — this file is the only positive evidence of its backend a reader gets.
# See wait-for-session.sh's dispatch block for the whole contract.
echo headless > "$CALL_DIR/transport.txt"
# Persist receiver cwd + [MODE:]/[CALLER:]/[SESSION:] tags from the ringing
# prompt so wait-for-session.sh can register the call in the sessions registry.
# The prompt goes on STDIN, so it needs a file inside the call dir either way:
# the background worker outlives this shell, so it cannot inherit a here-string.
# 0600 in a 0700 mktemp dir — a work order is exactly what other local users must
# not be able to read.
STDIN_PROMPT="$CALL_DIR/prompt.txt"
( umask 077; printf '%s' "$PROMPT" > "$STDIN_PROMPT" )
chmod 600 "$STDIN_PROMPT" 2>/dev/null || true

if [[ -n "$PROMPT_FILE" ]]; then
  bash "$(dirname "${BASH_SOURCE[0]}")/persist-call-meta.sh" "$CALL_DIR" "$CWD" --prompt-file "$PROMPT_FILE"
else
  bash "$(dirname "${BASH_SOURCE[0]}")/persist-call-meta.sh" "$CALL_DIR" "$CWD" --prompt-file "$STDIN_PROMPT"
fi

# Build the command. NO positional prompt: it arrives on stdin (see above).
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
    (cd "$EXEC_DIR" && "${CMD[@]}" <"$STDIN_PROMPT" 2>"$STDERR_FILE") | while IFS= read -r line; do
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
    "${CMD[@]}" <"$STDIN_PROMPT" 2>"$STDERR_FILE" | while IFS= read -r line; do
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

  # claude has exited, so the stdin copy of the prompt has served its purpose.
  # The receiver's own transcript is the record of what was asked.
  rm -f "$STDIN_PROMPT"

  # Parse final response
  #
  # NOTE: plugins/hotline/tests/wait-for-response_test.sh mirrors this
  # extraction block in `synthesize_response()` so the regression suite can
  # exercise the emission path without invoking `claude -p`. If you change
  # the logic below (result-line selection, fallback order, warning text),
  # update the test helper too or the tests will silently pass against a
  # stale mirror.
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
