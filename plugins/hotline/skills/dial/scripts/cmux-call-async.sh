#!/usr/bin/env bash
# =============================================================================
# CMUX Call (Async): Launch an interactive claude session inside a cmux
# workspace and return immediately. The caller drives polling for session-id
# and response through wait-for-session.sh / wait-for-response.sh — those
# scripts run as children of the caller's bash (which is cmux-spawned via
# claude's Bash tool), so they retain cmux ancestry and `cmux read-screen`
# works. This script does NOT background a poller of its own: under cmux's
# default access_mode=cmuxOnly, a detached subshell reparents to PID 1 and
# every `cmux` call returns "Broken pipe", silently breaking detection.
#
# Same call_dir interface as headless-call-async.sh:
#   workspace_ref.txt    — the cmux workspace ref (signals "cmux mode" to
#                          the wait-for-* scripts)
#   session_id_preset.txt — the UUID we passed to `claude --session-id`,
#                          confirmed by wait-for-session.sh when the splash
#                          banner appears (then promoted to session_id.txt)
#   launch_script.txt    — absolute path of the /tmp/hotline-launch-* file
#                          (wait-for-response.sh cleans it up after STATUS)
#   keep_workspace.txt   — 'true'/'false'; if true, wait-for-response.sh
#                          leaves the workspace open after STATUS (used by
#                          conference-call mode handed off to the user)
#   session_id.txt       — written by wait-for-session.sh after it observes
#                          the Claude Code REPL banner
#   response.json        — written by wait-for-response.sh after STATUS:
#                          {"session_id":"..","response":".."}
#   done                 — empty sentinel written by wait-for-response.sh
#   error.txt            — written by this script on early failures
#                          (new-workspace fail, send fail)
#
# Usage:
#   cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
#                      [--name <name>] [--fork-session] [--tools <list>]
#                      [--keep-workspace]
#   # Returns immediately with: {"call_dir": "/tmp/hotline-call-xxxxx"}
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
                          [--name <name>] [--fork-session]
                          [--tools <list>] [--keep-workspace]

Opens an interactive claude session in a cmux workspace and returns immediately
with {"call_dir": "/tmp/hotline-call-XXXXX"}. The caller then drives polling
via wait-for-session.sh and wait-for-response.sh — those scripts read
workspace_ref.txt from the call_dir to detect cmux mode and poll the cmux
workspace screen directly (they retain cmux ancestry, this script's
background subshell would not).

Options:
  --tools <list>     Allowed tools (default: "Bash Read Edit Write Grep Glob")
  --keep-workspace   Do not close the cmux workspace after STATUS. Used by
                     conference-call mode to hand the workspace off to the
                     user. wait-for-response.sh reads keep_workspace.txt.

To enable --dangerously-skip-permissions on the receiver (autonomous calls
into a trusted local workspace), set HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1
(or true/yes) in your env. See README for the trade-off.
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
# Placement: where the callee's claude session lands.
#   sidebyside (default) — a visible surface next to the caller's pane in the
#                          SAME cmux window (open-side-surface.sh).
#   detached             — today's behavior: a disconnected new-workspace tab.
#   window               — a surface in a specific window (open-window-surface.sh).
PLACEMENT="sidebyside"
WINDOW_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)            CWD="$2";            shift 2 ;;
    --prompt)         PROMPT="$2";         shift 2 ;;
    --resume)         RESUME_ID="$2";      shift 2 ;;
    --name)           SESSION_NAME="$2";   shift 2 ;;
    --fork-session)   FORK_SESSION=true;   shift   ;;
    --tools)          ALLOWED_TOOLS="$2";  shift 2 ;;
    --keep-workspace) KEEP_WORKSPACE=true; shift   ;;
    # Opt out of side-by-side: restore the original new-workspace placement.
    --detached|--new-workspace) PLACEMENT="detached"; shift ;;
    # Land in a specific window (find-or-create), for grouping workers by project.
    --window)         PLACEMENT="window"; WINDOW_REF="$2"; shift 2 ;;
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

# --fork-session COPIES the resumed session's transcript into a new id. With no
# --resume target there is nothing to copy, so claude generates a fresh --session-id
# and forks an EMPTY session — the call appears to succeed but the receiver reports
# "fresh session, nothing run here". In hotline usage --fork-session is only ever
# valid alongside --resume, so refuse the combination instead of silently forking
# nothing.
if $FORK_SESSION && [[ -z "$RESUME_ID" ]]; then
  echo '{"error": "--fork-session requires --resume <id>; forking with no resume target silently creates an empty session"}'
  exit 1
fi

CALL_DIR=$(mktemp -d /tmp/hotline-call-XXXXX)
echo "$KEEP_WORKSPACE" > "$CALL_DIR/keep_workspace.txt"
# Persist CWD so wait-for-session.sh can compute the claude transcript path
# (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl) as a second REPL-boot
# signal alongside the read-screen banner regex. Only written when known.
[[ -n "$CWD" ]] && echo "$CWD" > "$CALL_DIR/cwd.txt"

# Determine the session ID upfront. We don't write it to session_id.txt yet —
# wait-for-session.sh promotes session_id_preset.txt → session_id.txt only
# after it sees the REPL banner. That way the "session ID is available"
# signal genuinely means "claude is up", not "the wrapper generated a UUID".
#
# First contact (no --resume): generate a fresh UUID and pass it to claude via
# --session-id so the transcript is written under our chosen ID.
#
# Follow-up (--resume): the session already exists — use RESUME_ID directly.
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
[[ -n "$SESSION_ID_PRESET" ]] && echo "$SESSION_ID_PRESET" > "$CALL_DIR/session_id_preset.txt"

# Per-call nonce. Prevents replayed STATUS lines (e.g. `claude --resume`
# replaying the prior transcript into a fresh workspace's scrollback) from
# being mistaken for completion of THIS call. The receiver echoes the nonce
# back as `STATUS: <signal> call_id=<nonce>`; wait-for-response.sh ignores
# any STATUS line whose nonce doesn't match. 16 hex chars is plenty for
# disambiguation and keeps the marker compact in scrollback.
CALL_ID=$(
  openssl rand -hex 8 2>/dev/null \
  || od -A n -N 8 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n' \
  || date +%s%N | sha256sum 2>/dev/null | cut -c1-16
)
echo "$CALL_ID" > "$CALL_DIR/call_id.txt"
# Insert [CALL_ID: ...] into the prompt so the receiver can parse it and
# include it in its STATUS markers. If the prompt begins with a slash command
# (e.g. /hotline-ringing), the CALL_ID must go AFTER the command token —
# otherwise the leading bracket prevents claude from parsing the slash command
# at all. For non-slash prompts, prepend as before.
if [[ "$PROMPT" == /* ]]; then
  # Split on first space: "<cmd> <rest>" -> "<cmd> [CALL_ID: ...] <rest>"
  CMD_TOKEN="${PROMPT%% *}"
  REST="${PROMPT#* }"
  if [[ "$CMD_TOKEN" == "$PROMPT" ]]; then
    # No space — prompt is just the slash command itself
    PROMPT="$CMD_TOKEN [CALL_ID: $CALL_ID]"
  else
    PROMPT="$CMD_TOKEN [CALL_ID: $CALL_ID] $REST"
  fi
else
  PROMPT="[CALL_ID: $CALL_ID] $PROMPT"
fi

# Write a launch script so the full prompt reaches claude without escaping
# issues. printf %q produces bash-safe quoting for newlines, brackets, etc.
# chmod 700 prevents other local users from reading prompt contents.
LAUNCH_SCRIPT=$(mktemp /tmp/hotline-launch-XXXXX)
chmod 700 "$LAUNCH_SCRIPT"
{
  printf '#!/usr/bin/env bash\n'
  # Side-by-side / windowed surfaces inherit the CALLER's shell cwd, not the
  # target workspace's — unlike `cmux new-workspace --cwd`, which sets it. cd
  # into the target dir so the callee's claude session resolves files (and
  # --resume's cwd-matched session) correctly. Harmless for the detached path
  # where the new workspace already opened in CWD.
  [[ -n "$CWD" ]] && printf 'cd %q || exit 1\n' "$CWD"
  printf 'claude'
  [[ -n "$RESUME_ID"         ]] && printf ' --resume %q'     "$RESUME_ID"
  [[ -z "$RESUME_ID" && -n "$SESSION_ID_PRESET" ]] && \
                                    printf ' --session-id %q' "$SESSION_ID_PRESET"
  $FORK_SESSION                && printf ' --fork-session'
  [[ -n "$SESSION_NAME"      ]] && printf ' -n %q'           "$SESSION_NAME"
  # Opt-in via HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS — see README. Hotline
  # calls land in an unattended pane, so without this the receiver stalls on
  # the first permission gate. Off by default; it's a real trust decision.
  case "${HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS:-}" in
    1|true|TRUE|yes|YES) printf ' --dangerously-skip-permissions' ;;
  esac
  printf ' --allowedTools %q' "$ALLOWED_TOOLS"
  # `--` is REQUIRED before the positional prompt because --allowedTools is
  # variadic (`<tools...>`) and would otherwise swallow the prompt as an
  # extra "tool" name. Reproduced live: omitting `--` causes claude to start
  # with an empty REPL ("No conversation yet"), losing the prompt entirely.
  printf ' -- %q\n' "$PROMPT"
} > "$LAUNCH_SCRIPT"
echo "$LAUNCH_SCRIPT" > "$CALL_DIR/launch_script.txt"

# Common early-failure exit: write error.txt + done, drop the launch script,
# return the call_dir (the async contract: the launcher always returns a usable
# call_dir; the wait-for-* scripts surface the error).
fail_async() {
  jq -n --arg err "$1" '{error: $err}' > "$CALL_DIR/error.txt"
  touch "$CALL_DIR/done"
  rm -f "$LAUNCH_SCRIPT"
  jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
  exit 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$PLACEMENT" == "detached" ]]; then
  # ---- Detached: today's behavior — a new workspace tab. -------------------
  # --focus true is REQUIRED: without it cmux does not spawn a real tty for the
  # workspace's terminal surface, and subsequent `cmux send` / `cmux read-screen`
  # calls fail with "Terminal surface not found". Discovered via live testing.
  WS_NAME="${SESSION_NAME:-hotline}"
  if ! WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" --name "$WS_NAME" --focus true 2>&1); then
    fail_async "cmux new-workspace failed: $WS_OUTPUT"
  fi
  WS_REF=$(echo "$WS_OUTPUT" | grep -oE 'workspace:[0-9]+' | head -1 || true)
  [[ -z "$WS_REF" ]] && fail_async "cmux new-workspace failed: $WS_OUTPUT"
  echo "$WS_REF" > "$CALL_DIR/workspace_ref.txt"
  SEND_TARGET=(--workspace "$WS_REF")

  # Wait for the workspace shell to be ready before firing the launch script.
  # Poll until the screen is non-empty (up to 5s) rather than a fixed sleep.
  for _ in $(seq 1 10); do
    INIT_SCREEN=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
      2>/dev/null || true)
    [[ -n "$INIT_SCREEN" ]] && break
    sleep 0.5
  done
else
  # ---- Surface placements: side-by-side (default) or a specific window. -----
  # Both open a VISIBLE terminal surface and wait until its PTY is attached and
  # the shell is executing input (--wait-ready) — the surface-mode equivalent
  # of `new-workspace --focus true`. This protects the fresh-PTY race (a
  # swallowed launch-command \n) and "Terminal surface not found" (PTY not yet
  # attached). The opener always returns the surface ref even on a readiness
  # timeout, so we never orphan a surface.
  READY_TIMEOUT="${HOTLINE_SURFACE_READY_TIMEOUT:-8}"
  if [[ "$PLACEMENT" == "window" ]]; then
    [[ -z "$WINDOW_REF" ]] && fail_async "--window requires a name or ref"
    SURF_JSON=$(bash "$SCRIPT_DIR/open-window-surface.sh" --window "$WINDOW_REF" \
      ${CWD:+--working-directory "$CWD"} --wait-ready --wait-ready-timeout "$READY_TIMEOUT" \
      --json 2>"$CALL_DIR/surface_err.txt") \
      || fail_async "open-window-surface.sh failed: $(cat "$CALL_DIR/surface_err.txt" 2>/dev/null)"
  else
    SURF_JSON=$(bash "$SCRIPT_DIR/open-side-surface.sh" --caller --wait-ready \
      --wait-ready-timeout "$READY_TIMEOUT" --json 2>"$CALL_DIR/surface_err.txt") \
      || fail_async "open-side-surface.sh failed: $(cat "$CALL_DIR/surface_err.txt" 2>/dev/null)"
  fi

  SURF_REF=$(printf '%s' "$SURF_JSON" | jq -r '.surface_ref // empty')
  SURF_PANE=$(printf '%s' "$SURF_JSON" | jq -r '.pane_ref // empty')
  SURF_READY=$(printf '%s' "$SURF_JSON" | jq -r '.ready // empty')
  [[ -z "$SURF_REF" ]] && fail_async "surface opener returned no surface_ref: $SURF_JSON"

  if [[ "$SURF_READY" == "timeout" ]]; then
    # PTY never confirmed ready — sending now would likely drop the launch
    # command's \n. Close the surface we created and fail loudly rather than
    # leave a wedged surface behind.
    cmux close-surface --surface "$SURF_REF" >/dev/null 2>&1 || true
    fail_async "surface $SURF_REF PTY never became ready (see surface_err.txt)"
  fi

  # surface_ref.txt is the cmux-SURFACE-mode signal to the wait-for-* scripts
  # (mirrors how workspace_ref.txt signals workspace mode). pane_ref.txt lets
  # them re-attach the PTY if a read-screen ever races.
  echo "$SURF_REF" > "$CALL_DIR/surface_ref.txt"
  [[ -n "$SURF_PANE" ]] && echo "$SURF_PANE" > "$CALL_DIR/pane_ref.txt"
  SEND_TARGET=(--surface "$SURF_REF")
  # Surface placements live in the caller's own window — keep them visible after
  # the call instead of auto-closing (the whole point is to SEE the call). The
  # caller closes the surface when done.
  KEEP_WORKSPACE=true
  echo "$KEEP_WORKSPACE" > "$CALL_DIR/keep_workspace.txt"
fi

# Fire the claude session into whichever surface/workspace we landed on.
if ! SEND_OUTPUT=$(cmux send "${SEND_TARGET[@]}" "bash $LAUNCH_SCRIPT\n" 2>&1); then
  if [[ "$PLACEMENT" == "detached" ]]; then
    [[ "$KEEP_WORKSPACE" != "true" ]] && \
      cmux close-workspace "${SEND_TARGET[@]}" 2>/dev/null || true
  fi
  fail_async "cmux send failed: $SEND_OUTPUT"
fi

jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
