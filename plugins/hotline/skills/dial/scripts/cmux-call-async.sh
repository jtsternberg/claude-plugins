#!/usr/bin/env bash
# =============================================================================
# CMUX Call (Async): Deliver a hotline prompt to an interactive claude session
# running inside a cmux workspace, then poll cmux read-screen for completion.
#
# Prefers interactive claude (no -p flag) over headless so calls do not consume
# programmatic usage credits. The hotline protocol (STATUS signals, response
# format) is defined by the ringing skill, not the transport, so the response
# format is identical either way.
#
# Same call_dir interface as headless-call-async.sh:
#   session_id.txt    — written by the background poller AFTER it observes the
#                       Claude Code REPL banner in cmux read-screen (so
#                       wait-for-session.sh blocks until claude is really up,
#                       not just when the wrapper script generated a UUID).
#                       Contents are the preset --session-id UUID.
#   response.json     — {"session_id":"..","response":".."} on completion
#   done              — empty sentinel written when call finishes
#   error.txt         — written on failure
#   workspace_ref.txt — the cmux workspace ref (kept open unless --keep-workspace
#                       is passed by a conference call caller; quick/work callers
#                       get it cleaned up automatically)
#
# Usage:
#   cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
#                      [--name <name>] [--fork-session] [--tools <list>]
#                      [--keep-workspace] [--max-wait <seconds>]
#   # Returns immediately with: {"call_dir": "/tmp/hotline-call-xxxxx"}
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
                          [--name <name>] [--fork-session]
                          [--tools <list>] [--keep-workspace]
                          [--max-wait <seconds>]

Opens an interactive claude session in a cmux workspace, delivers the hotline
prompt via a temp launch script, and polls cmux read-screen for STATUS signals.

Returns immediately with {"call_dir": "/tmp/hotline-call-XXXXX"}.
The caller uses wait-for-session.sh and wait-for-response.sh as normal.

Options:
  --tools <list>     Allowed tools (default: "Bash Read Edit Write Grep Glob")
  --keep-workspace   Do not close the cmux workspace after the call completes.
                     workspace_ref.txt in the call_dir always has the ref.
  --max-wait <secs>  How long the poller waits for a terminal STATUS line.
                     Default: 1800 (30 minutes).

STATUS signals polled for:
  STATUS: DONE           — quick call complete
  STATUS: WORK_COMPLETE  — work order complete
  STATUS: OUT_OF_SCOPE   — workspace declined the work
  STATUS: WORK_IN_PROGRESS — still running (keeps polling)
EOF
  exit 0
fi

CWD=""
PROMPT=""
RESUME_ID=""
SESSION_NAME=""
FORK_SESSION=false
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"
KEEP_WORKSPACE=false
MAX_WAIT=1800

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)            CWD="$2";            shift 2 ;;
    --prompt)         PROMPT="$2";         shift 2 ;;
    --resume)         RESUME_ID="$2";      shift 2 ;;
    --name)           SESSION_NAME="$2";   shift 2 ;;
    --fork-session)   FORK_SESSION=true;   shift   ;;
    --tools)          ALLOWED_TOOLS="$2";  shift 2 ;;
    --keep-workspace) KEEP_WORKSPACE=true; shift   ;;
    --max-wait)       MAX_WAIT="$2";       shift 2 ;;
    *)                shift ;;
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

# Determine the session ID upfront so wait-for-session.sh returns immediately.
#
# First contact (no --resume): generate a fresh UUID and pass it to claude via
# --session-id so the transcript is written under our chosen ID.
#
# Follow-up (--resume): the session already exists — use RESUME_ID directly.
# Do NOT generate a new UUID; that would write a wrong ID to session_id.txt.
#
# uuidgen (macOS/Linux), /proc/sys/kernel/random/uuid, and /dev/urandom are
# tried in order so the script degrades gracefully on minimal systems.
SESSION_ID_PRESET=""
if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID_PRESET="$RESUME_ID"
else
  SESSION_ID_PRESET=$(
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' \
    || cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || {
         b=$(od -A n -N 16 -t x1 /dev/urandom | tr -d ' \n')
         printf '%s-%s-4%s-%x%s-%s\n' \
           "${b:0:8}" "${b:8:4}" "${b:13:3}" \
           "$(( (16#${b:16:1} & 0x3) | 0x8 ))" "${b:17:3}" "${b:20:12}"
       } \
    || true
  )
fi
# NOTE: session_id.txt is intentionally NOT written here. Writing it upfront
# (the previous behavior) made wait-for-session.sh return instantly, even
# when claude never actually started — callers treated that as "connected"
# and waited 30 minutes for STATUS lines from a session that never existed
# (see failed-hotline-call.txt postmortem). The background poller below
# writes session_id.txt only after observing the Claude Code REPL banner in
# cmux read-screen, so wait-for-session.sh now blocks until claude is really
# up — or fails fast at SESSION_START_DEADLINE if the REPL never appears.

# Write a launch script so the full prompt reaches claude without escaping
# issues. printf %q produces bash-safe quoting for newlines, brackets, etc.
# chmod 700 prevents other local users from reading prompt contents.
LAUNCH_SCRIPT=$(mktemp /tmp/hotline-launch-XXXXX)
chmod 700 "$LAUNCH_SCRIPT"
{
  printf '#!/usr/bin/env bash\n'
  printf 'claude'
  [[ -n "$RESUME_ID"         ]] && printf ' --resume %q'     "$RESUME_ID"
  [[ -z "$RESUME_ID" && -n "$SESSION_ID_PRESET" ]] && \
                                    printf ' --session-id %q' "$SESSION_ID_PRESET"
  $FORK_SESSION                && printf ' --fork-session'
  [[ -n "$SESSION_NAME"      ]] && printf ' -n %q'           "$SESSION_NAME"
  printf ' --allowedTools %q' "$ALLOWED_TOOLS"
  # `--` is REQUIRED before the positional prompt because --allowedTools is
  # variadic (`<tools...>`) and would otherwise swallow the prompt as an
  # extra "tool" name. Reproduced live: omitting `--` causes claude to start
  # with an empty REPL ("No conversation yet"), losing the prompt entirely.
  # This was the root cause of the original hotline-call hang.
  printf ' -- %q\n' "$PROMPT"
} > "$LAUNCH_SCRIPT"

# Open cmux workspace. --focus true is REQUIRED: without it cmux does not spawn
# a real tty for the workspace's terminal surface, and subsequent `cmux send`
# and `cmux read-screen` calls fail with "Terminal surface not found" /
# "Surface is not a terminal". Discovered via live testing.
WS_NAME="${SESSION_NAME:-hotline}"
if ! WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" --name "$WS_NAME" --focus true 2>&1); then
  jq -n --arg err "cmux new-workspace failed: $WS_OUTPUT" '{error: $err}' \
    > "$CALL_DIR/error.txt"
  touch "$CALL_DIR/done"
  rm -f "$LAUNCH_SCRIPT"
  jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
  exit 0
fi
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

# Wait for the workspace shell to be ready before snapshotting the baseline.
# Poll until the screen is non-empty (up to 5s) rather than a fixed sleep.
PRE_LINES=0
for _ in $(seq 1 10); do
  INIT_SCREEN=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
    2>/dev/null || true)
  if [[ -n "$INIT_SCREEN" ]]; then
    PRE_LINES=$(echo "$INIT_SCREEN" | wc -l | awk '{print $1}')
    break
  fi
  sleep 0.5
done

# Fire the claude session.
if ! SEND_OUTPUT=$(cmux send --workspace "$WS_REF" "bash $LAUNCH_SCRIPT\n" 2>&1); then
  jq -n --arg err "cmux send failed: $SEND_OUTPUT" '{error: $err}' \
    > "$CALL_DIR/error.txt"
  [[ "$KEEP_WORKSPACE" != "true" ]] && \
    cmux close-workspace --workspace "$WS_REF" 2>/dev/null || true
  rm -f "$LAUNCH_SCRIPT"
  touch "$CALL_DIR/done"
  jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
  exit 0
fi

# Background poller: reads screen until a terminal STATUS signal appears.
# Exported vars are inherited; no temp files needed for hand-off.
export WS_REF LAUNCH_SCRIPT KEEP_WORKSPACE PRE_LINES MAX_WAIT \
       SESSION_ID_PRESET CALL_DIR
(
  ELAPSED=0
  POLL_INTERVAL=1
  ESC=$(printf '\x1b')
  SESSION_STARTED=false
  SESSION_START_DEADLINE=60

  finish() {
    local session_id="$1" response="$2" is_error="${3:-false}"
    if [[ "$is_error" == "true" ]]; then
      echo "$response" > "$CALL_DIR/error.txt"
    else
      jq -n --arg sid "$session_id" --arg resp "$response" \
        '{session_id: $sid, response: $resp}' > "$CALL_DIR/response.json"
    fi
    [[ "$KEEP_WORKSPACE" != "true" ]] && \
      cmux close-workspace --workspace "$WS_REF" 2>/dev/null || true
    rm -f "$LAUNCH_SCRIPT"
    touch "$CALL_DIR/done"
  }

  # If the poller is killed (parent dies, system shutdown, etc.), still clean
  # up the launch script and close the workspace so we don't leak resources.
  trap '
    rm -f "$LAUNCH_SCRIPT"
    [[ "$KEEP_WORKSPACE" != "true" ]] && \
      cmux close-workspace --workspace "$WS_REF" 2>/dev/null || true
  ' EXIT

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    SCREEN=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
      2>/dev/null || true)
    [[ -z "$SCREEN" ]] && continue

    # Isolate lines added since the baseline snapshot.
    TOTAL=$(echo "$SCREEN" | wc -l | awk '{print $1}')
    NEW_COUNT=$((TOTAL - PRE_LINES))
    [[ $NEW_COUNT -le 0 ]] && NEW_COUNT="$TOTAL"
    NEW_CONTENT=$(echo "$SCREEN" | tail -n "$NEW_COUNT")
    # Strip ANSI escape sequences and carriage returns before any line-oriented
    # matching. cmux may return colorized terminal output, including colored
    # STATUS lines, and raw matching would miss those completion signals.
    CLEAN=$(echo "$NEW_CONTENT" \
      | sed "s/${ESC}\[[0-9;]*[mGKHFJKsu]//g; s/${ESC}(B//g; s/\r//g")

    # Stage 1: wait for the Claude Code REPL to actually boot before writing
    # session_id.txt. Without this gate, wait-for-session.sh returns
    # instantly (because session_id.txt was written upfront) and the caller
    # thinks claude is up when it isn't. The splash banner ("Claude Code v"
    # in the top of the box, or "Welcome back" in the welcome line) is the
    # earliest reliable evidence the REPL exists.
    if ! $SESSION_STARTED; then
      if echo "$CLEAN" | grep -qE 'Claude Code v|Welcome back'; then
        [[ -n "$SESSION_ID_PRESET" ]] && \
          echo "$SESSION_ID_PRESET" > "$CALL_DIR/session_id.txt"
        SESSION_STARTED=true
      elif [[ $ELAPSED -ge $SESSION_START_DEADLINE ]]; then
        finish "" "Claude REPL did not boot within ${SESSION_START_DEADLINE}s. cmux send succeeded but no Claude Code banner appeared on screen. Common causes: (a) launch-script claude invocation is malformed — e.g. --allowedTools without a -- separator before the positional prompt, which silently consumes the prompt as a tool name and leaves an empty REPL; (b) workspace was opened without --focus true, so the terminal surface has no tty. Inspect $LAUNCH_SCRIPT and the cmux workspace screen for the real failure." true
        exit 0
      fi
      continue
    fi

    # Stage 2: find the LATEST STATUS line in the screen. Live testing showed that the
    # "last meaningful line" heuristic is fragile against trailing terminal
    # chrome (shell prompts, the claude REPL's `│ > │` box bottom, etc.) — any
    # of those would appear after the real STATUS and defeat the check.
    #
    # "Latest STATUS line anywhere wins" matches what real receivers do: emit
    # the terminal STATUS at the very tail of their message. A receiver that
    # *quotes* a STATUS string mid-response would still put its real STATUS
    # after it, so the latest occurrence is correct. The only failure mode is
    # a receiver that quotes the protocol AFTER its own final STATUS line —
    # an acceptable corner case.
    LATEST_STATUS=$(echo "$CLEAN" | awk '/^STATUS: /{s=$0} END{print s}')

    if [[ "$LATEST_STATUS" == "STATUS: WORK_IN_PROGRESS" ]]; then
      continue
    fi

    # Terminal statuses — extract response and wrap up.
    if [[ "$LATEST_STATUS" =~ ^STATUS:\ (WORK_COMPLETE|OUT_OF_SCOPE|DONE)$ ]]; then
      # Strip terminal chrome before extracting the response. The aggressive
      # prefix match (any line starting with `╭│╰─└┌┘┐ℹ`) is needed because
      # the claude REPL renders its idle prompt as a multi-line box where the
      # middle line `│ > │` carries text — a stricter "pure chrome only"
      # regex leaves that line in the response. The tradeoff is that response
      # bodies rendering ASCII art with these specific Unicode box chars get
      # stripped. Real responses almost never include them.
      #
      # Lines we strip:
      #   - the `bash /tmp/hotline-launch-*` command echoed at the prompt
      #   - lines starting with claude's banner / box-drawing characters
      #   - claude's "ℹ ..." info lines (update available / tip banners)
      #   - the bare REPL prompt `> ` on its own line (multi-line markdown
      #     blockquotes start with `> text` and survive)
      #
      # Response extraction: walk the lines, resetting the buffer on every
      # WORK_IN_PROGRESS signal and saving the buffer on every terminal
      # STATUS line. At END, emit the LAST saved buffer — that matches the
      # LATEST_STATUS we just chose for detection.
      RESPONSE=$(echo "$CLEAN" \
        | grep -v "^bash /tmp/hotline-launch" \
        | grep -vE "^[╭│╰─└┌┘┐ℹ]" \
        | grep -vE "^>[[:space:]]*$" \
        | awk '
            /^STATUS: WORK_IN_PROGRESS$/ {buf=""; next}
            /^STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE)$/ {result=buf; buf=""; next}
            {buf = buf $0 ORS}
            END {printf "%s", result}
          ')

      finish "$SESSION_ID_PRESET" "$RESPONSE"
      exit 0
    fi
  done

  finish "" "Timeout: no STATUS signal received after ${MAX_WAIT}s" true
) &>/dev/null &

jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
