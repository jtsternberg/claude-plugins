#!/usr/bin/env bash
# =============================================================================
# CMUX Call (Async): Deliver a hotline prompt to an interactive claude session
# running inside a cmux workspace, then poll cmux read-screen for completion.
#
# Prefers interactive claude (no -p flag) over headless so calls do not consume
# programmatic usage credits. The hotline protocol (STATUS signals) is defined
# by the ringing skill, not the transport, so the response format is identical.
#
# Same call_dir interface as headless-call-async.sh:
#   session_id.txt    — written if SESSION_ID: tag found in response
#   response.json     — {"session_id":"..","response":".."} on completion
#   done              — empty sentinel written when call finishes
#   error.txt         — written on failure
#   workspace_ref.txt — the cmux workspace ref (for follow-up calls)
#
# Usage:
#   cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
#                      [--name <name>] [--fork-session]
#   # Returns immediately with: {"call_dir": "/tmp/hotline-call-xxxxx"}
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
                          [--name <name>] [--fork-session]

Opens an interactive claude session in a cmux workspace, delivers the hotline
prompt via a temp launch script (avoids shell-escaping issues with complex
prompts), and polls cmux read-screen for STATUS completion signals.

Returns immediately with {"call_dir": "/tmp/hotline-call-XXXXX"}.
The caller then uses wait-for-session.sh and wait-for-response.sh as normal.

STATUS signals polled for:
  STATUS: DONE           — quick call complete
  STATUS: WORK_COMPLETE  — work order complete
  STATUS: OUT_OF_SCOPE   — workspace declined the work
  STATUS: WORK_IN_PROGRESS — work order still running (keeps polling)
EOF
  exit 0
fi

CWD=""
PROMPT=""
RESUME_ID=""
SESSION_NAME=""
FORK_SESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)          CWD="$2";          shift 2 ;;
    --prompt)       PROMPT="$2";       shift 2 ;;
    --resume)       RESUME_ID="$2";    shift 2 ;;
    --name)         SESSION_NAME="$2"; shift 2 ;;
    --fork-session) FORK_SESSION=true; shift   ;;
    *)              shift ;;
  esac
done

if [[ -z "$CWD" && -z "$RESUME_ID" ]]; then
  echo '{"error": "No --cwd provided"}'
  exit 1
fi

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No --prompt provided"}'
  exit 1
fi

CALL_DIR=$(mktemp -d /tmp/hotline-call-XXXXX)

# Write a launch script so the full prompt reaches claude without escaping issues.
# printf %q produces bash-safe quoting that handles newlines, brackets, quotes, etc.
LAUNCH_SCRIPT=$(mktemp /tmp/hotline-launch-XXXXX.sh)
{
  printf '#!/usr/bin/env bash\n'
  printf 'claude'
  [[ -n "$RESUME_ID"   ]] && printf ' --resume %s'    "$RESUME_ID"
  $FORK_SESSION          && printf ' --fork-session'
  [[ -n "$SESSION_NAME" ]] && printf ' -n %q'          "$SESSION_NAME"
  printf ' %q\n' "$PROMPT"
} > "$LAUNCH_SCRIPT"
chmod +x "$LAUNCH_SCRIPT"

# Open cmux workspace.
WS_NAME="${SESSION_NAME:-hotline}"
WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" --name "$WS_NAME" 2>&1)
WS_REF=$(echo "$WS_OUTPUT" | grep -oE 'workspace:[0-9]+' | head -1 || true)

if [[ -z "$WS_REF" ]]; then
  jq -n --arg err "cmux new-workspace failed: $WS_OUTPUT" '{error: $err}' \
    > "$CALL_DIR/error.txt"
  touch "$CALL_DIR/done"
  rm -f "$LAUNCH_SCRIPT"
  jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
  exit 0
fi

echo "$WS_REF" > "$CALL_DIR/workspace_ref.txt"

# Snapshot current line count so the poller can isolate new output.
sleep 0.5
PRE_LINES=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
  2>/dev/null | wc -l | tr -d ' ' || echo 0)
echo "$PRE_LINES" > "$CALL_DIR/pre_lines.txt"

# Fire the claude session.
cmux send --workspace "$WS_REF" "bash $LAUNCH_SCRIPT\n"

# Background poller: reads screen until a terminal STATUS signal appears.
(
  MAX_WAIT=300
  ELAPSED=0
  POLL_INTERVAL=3
  PRE=$(cat "$CALL_DIR/pre_lines.txt" 2>/dev/null || echo 0)

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    SCREEN=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
      2>/dev/null || true)
    [[ -z "$SCREEN" ]] && continue

    # Extract only lines added since launch.
    TOTAL=$(echo "$SCREEN" | wc -l | tr -d ' ')
    NEW_COUNT=$((TOTAL - PRE))
    [[ $NEW_COUNT -le 0 ]] && NEW_COUNT="$TOTAL"
    NEW_CONTENT=$(echo "$SCREEN" | tail -n "$NEW_COUNT")

    # WORK_IN_PROGRESS means keep polling — the remote agent isn't done yet.
    if echo "$NEW_CONTENT" | grep -qE "^STATUS: WORK_IN_PROGRESS$"; then
      continue
    fi

    # Terminal statuses: extract and write response.
    if echo "$NEW_CONTENT" | grep -qE "^STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE)$"; then
      # Strip terminal chrome: banner box-drawing chars, claude prompts, the
      # launch command line, and leading/trailing blank lines.
      RESPONSE=$(echo "$NEW_CONTENT" \
        | grep -v "^bash /tmp/hotline-launch" \
        | grep -vE "^[╭│╰ℹ>]" \
        | awk '/^STATUS: /{exit} {print}' \
        | sed '/^[[:space:]]*$/d')

      SESSION_ID=$(echo "$NEW_CONTENT" \
        | grep -oE '^SESSION_ID: [a-f0-9-]+' \
        | awk '{print $2}' | head -1 || true)

      [[ -n "$SESSION_ID" ]] && echo "$SESSION_ID" > "$CALL_DIR/session_id.txt"

      jq -n --arg sid "${SESSION_ID:-}" --arg resp "$RESPONSE" \
        '{session_id: $sid, response: $resp}' > "$CALL_DIR/response.json"
      touch "$CALL_DIR/done"
      rm -f "$LAUNCH_SCRIPT"
      exit 0
    fi
  done

  jq -n --arg err "Timeout: no STATUS signal received after ${MAX_WAIT}s" \
    '{error: $err}' > "$CALL_DIR/error.txt"
  touch "$CALL_DIR/done"
  rm -f "$LAUNCH_SCRIPT"
) &>/dev/null &

jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
