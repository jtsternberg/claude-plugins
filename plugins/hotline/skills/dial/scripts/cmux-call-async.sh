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
#   launch_script.txt    — absolute path of the launch script. Starts as the
#                          /tmp/hotline-launch-* file the callee's shell execs;
#                          wait-for-session.sh moves that into the call dir as
#                          launch_script.sh once boot confirms and repoints this,
#                          and wait-for-response.sh removes whatever it names
#                          after STATUS. A boot that FAILED leaves the /tmp path
#                          in place — the diagnostic tells the user to re-send it
#                          by hand — and the age sweep below reaps those.
#   pending_paste.md     — the prompt, 0600, awaiting delivery into the booted
#                          REPL by cmux-paste.sh. Present in cmux surface/workspace
#                          mode only; its presence is the signal to the caller
#                          that a delivery step is still owed (see below).
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
# THE PROMPT IS NOT LAUNCHED WITH CLAUDE. This script starts a BARE `claude`
# REPL and leaves the prompt in pending_paste.md for cmux-paste.sh to deliver
# once the REPL's input box is up. It used to pass the prompt as claude's
# positional argument, which put whole work orders in an argv every local user
# can read out of `ps` (claude-plugins-86ka) — and meant first contact and
# follow-ups used two entirely different delivery mechanisms, only one of which
# was ever verified byte-exact. Now both paste over the control socket.
#
# The caller owes the delivery step: launch here, boot wait (wait-for-session.sh),
# then paste. That ordering is why the prompt cannot be delivered from inside this
# script — it returns before the REPL exists.
#
# Usage:
#   cmux-call-async.sh --cwd <path> (--prompt <text> | --prompt-file <path>)
#                      [--resume <id>] [--name <name>] [--fork-session]
#                      [--tools <list>] [--keep-workspace]
#   # Returns immediately with: {"call_dir": "/tmp/hotline-call-xxxxx"}
#
# --prompt-file is preferred: it keeps the payload out of argv end to end.
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
PROMPT_FILE=""
RESUME_ID=""
SESSION_NAME=""
FORK_SESSION=false
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"
KEEP_WORKSPACE=false
# Placement: where the callee's claude session lands.
#   sidebyside (default) — a visible surface next to the caller's pane in the
#                          SAME cmux window (via cmux-cli's open-side-surface.sh,
#                          resolved at runtime; headless fallback if absent).
#   detached             — original behavior: a disconnected new-workspace tab.
#   window               — a surface in a specific window (open-window-surface.sh).
PLACEMENT="sidebyside"
WINDOW_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)            CWD="$2";            shift 2 ;;
    --prompt)         PROMPT="$2";         shift 2 ;;
    --prompt-file)    PROMPT_FILE="$2";    shift 2 ;;
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

if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    jq -nc --arg p "$PROMPT_FILE" '{error: ("--prompt-file does not exist: " + $p)}'
    exit 1
  fi
  PROMPT=$(cat "$PROMPT_FILE")
fi

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No --prompt or --prompt-file provided"}'
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

# Side-by-side placement delegates to cmux-cli's canonical open-side-surface.sh
# (single source of truth — no vendored copy). cmux can be present without the
# cmux-cli plugin installed, in which case the opener won't resolve. Detect that
# BEFORE creating any call_dir / launch script and signal the dial skill to fall
# back to the HEADLESS transport (--detached / --window don't need the opener:
# detached uses new-workspace, --window uses hotline's own open-window-surface).
OPEN_SIDE_SURFACE=""
if [[ "$PLACEMENT" == "sidebyside" ]]; then
  if ! OPEN_SIDE_SURFACE=$(bash "$SCRIPT_DIR/resolve-side-opener.sh" 2>/dev/null); then
    jq -n '{fallback: "headless", reason: "cmux-cli open-side-surface.sh not found; side-by-side placement unavailable"}'
    exit 0
  fi
fi

# HOTLINE_CALL_HOME overrides the base dir (default /tmp) so test suites can own
# and wipe every call dir instead of littering /tmp (claude-plugins-cjgn).
CALL_DIR=$(mktemp -d "${HOTLINE_CALL_HOME:-/tmp}/hotline-call-XXXXX")
echo "$KEEP_WORKSPACE" > "$CALL_DIR/keep_workspace.txt"
# Persist CWD so wait-for-session.sh can compute the claude transcript path
# (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl) as a second REPL-boot
# signal alongside the read-screen banner regex. Only written when known.
[[ -n "$CWD" ]] && echo "$CWD" > "$CALL_DIR/cwd.txt"
# Persist [MODE:]/[CALLER:]/[SESSION:] tags from the ringing prompt so
# wait-for-session.sh can register the call in the sessions registry itself.
# Via the file when we have one, so the payload does not take an argv detour.
if [[ -n "$PROMPT_FILE" ]]; then
  bash "$SCRIPT_DIR/persist-call-meta.sh" "$CALL_DIR" "$CWD" --prompt-file "$PROMPT_FILE"
else
  bash "$SCRIPT_DIR/persist-call-meta.sh" "$CALL_DIR" "$CWD" "$PROMPT"
fi

# Determine the session ID upfront. We don't write it to session_id.txt yet —
# wait-for-session.sh promotes session_id_preset.txt → session_id.txt only
# after it sees the REPL banner. That way the "session ID is available"
# signal genuinely means "claude is up", not "the wrapper generated a UUID".
#
# cmux mode has no structured output to read the real session ID back from
# (headless parses it out of stream-json), so the preset must be *authoritative*
# — whatever we record here is what the wait-for-* scripts will treat as the
# callee's session. Three cases:
#
#   First contact (no --resume): generate a fresh UUID and pass it to claude via
#   --session-id so the transcript is written under our chosen ID.
#
#   Fork (--resume + --fork-session): the fork writes to a NEW session, so the
#   resume target is NOT where the transcript lands. Generate a fresh UUID and
#   pass it via --session-id — that is the only way to know the fork's ID.
#
#   Plain resume (--resume alone): the session already exists and keeps its ID —
#   use RESUME_ID and do NOT pass --session-id (claude rejects that combination).
#
# The CLI states the rule itself: "--session-id can only be used with --continue
# or --resume if --fork-session is also specified." So --session-id is REQUIRED
# on a fork and FORBIDDEN on a plain resume.
#
# uuidgen (macOS/Linux), /proc/sys/kernel/random/uuid, and /dev/urandom are
# tried in order so the script degrades gracefully on minimal systems.
#
# PRESET_IS_OURS: true when we chose the ID (first contact or fork) and must
# therefore tell claude about it; false when claude already owns it (plain
# resume). Drives the --session-id flag below.
SESSION_ID_PRESET=""
PRESET_IS_OURS=true
if [[ -n "$RESUME_ID" ]] && ! $FORK_SESSION; then
  SESSION_ID_PRESET="$RESUME_ID"
  PRESET_IS_OURS=false
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
CALL_ID=$(hotline_mint_call_id)
echo "$CALL_ID" > "$CALL_DIR/call_id.txt"
# Placement of the nonce inside the prompt is a shared rule, not a local one — see
# hotline_inject_call_id in repl-state.sh. Three copies of it had already drifted
# apart on where to split a slash command.
PROMPT=$(hotline_inject_call_id "$CALL_ID" "$PROMPT")

# The prompt waits here for delivery, and never reaches claude's argv. 0600 in a
# 0700 mktemp dir: a work order is exactly the payload other local users must not
# be able to read.
PENDING_PASTE="$CALL_DIR/pending_paste.md"
( umask 077; printf '%s' "$PROMPT" > "$PENDING_PASTE" )
chmod 600 "$PENDING_PASTE" 2>/dev/null || true

# The launch script exists to keep claude's flags off the `cmux send` line (which
# interprets \n/\r/\t) and to cd into the target dir. It carries no prompt.
# chmod 700 because it still names the session and the resume target.
#
# BEFORE minting a new one, reap the abandoned ones. Two prefixes, because both
# launchers write here (`hotline-cmux-launch-*` is cmux-call.sh's, whose in-script
# `trap … EXIT` self-delete does not fire when the surface is closed under it —
# 101 of those had survived alongside 291 of ours). Deletion on the happy path
# belongs to wait-for-session.sh at boot-confirm; this only catches what a failed
# or abandoned call left behind, so the floor is deliberately high: 7 days is long
# past any forensic value, and long past any surface still stuck on a refused
# launch line. Scoped to /tmp's own level, our own name patterns, regular files
# only, and best-effort — a dial must not fail because a sweep did
# (claude-plugins-qq9f). `HOTLINE_LAUNCH_SWEEP_DIR` exists so the suite can point
# the sweep at a scratch directory instead of the machine's real /tmp; nothing in
# the dial flow sets it.
# THE TRAILING SLASH IS LOAD-BEARING. On macOS /tmp is a symlink to private/tmp,
# and `find /tmp` without it descends nothing: find reports the symlink itself,
# which `-type f` then rejects, so the sweep silently matched 0 of 291 real files.
# `find /tmp/` follows it. Harmless on Linux, where /tmp is a real directory.
find "${HOTLINE_LAUNCH_SWEEP_DIR:-/tmp}/" -maxdepth 1 -type f \
  \( -name 'hotline-launch-*' -o -name 'hotline-cmux-launch-*' \) \
  -mtime +7 -delete 2>/dev/null || true

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
  # Model override, baked in at write time from the caller's env (the pane's
  # shell won't inherit it). e.g. HOTLINE_CLAUDE_MODEL=opus
  [[ -n "${HOTLINE_CLAUDE_MODEL:-}" ]] && printf ' --model %q' "$HOTLINE_CLAUDE_MODEL"
  [[ -n "$RESUME_ID"         ]] && printf ' --resume %q'     "$RESUME_ID"
  # --session-id only when the preset is OURS (first contact or fork). On a
  # plain resume claude owns the ID and rejects the flag outright.
  $PRESET_IS_OURS && [[ -n "$SESSION_ID_PRESET" ]] && \
                                    printf ' --session-id %q' "$SESSION_ID_PRESET"
  $FORK_SESSION                && printf ' --fork-session'
  [[ -n "$SESSION_NAME"      ]] && printf ' -n %q'           "$SESSION_NAME"
  # Opt-in via HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS — see README. Hotline
  # calls land in an unattended pane, so without this the receiver stalls on
  # the first permission gate. Off by default; it's a real trust decision.
  case "${HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS:-}" in
    1|true|TRUE|yes|YES) printf ' --dangerously-skip-permissions' ;;
  esac
  # `=`-joined into ONE argv word (`--allowedTools=Bash\ Read\ …`), never the
  # two-token `--allowedTools <list>` form. cmux's checkpoint recorder treats
  # `--allowedTools` as an arity-0 boolean and drops the value that follows it,
  # so the restore command it stores ends in a bare `'--allowedTools'` and
  # `cmux restore claude <id>` dies after a cmux restart with
  # "option '--allowedTools' argument missing". The `=` form keeps flag and
  # value in one argv element, which the recorder preserves byte-for-byte
  # (verified on cmux 0.64.22). claude accepts either form.
  #
  # No positional prompt follows, and so no `--` separator is needed: the REPL
  # comes up empty and receives the prompt by paste. (When a prompt DID ride here,
  # omitting `--` let variadic --allowedTools swallow it, which is how a call
  # could boot into "No conversation yet". That whole failure mode is gone.)
  printf ' --allowedTools=%q\n' "$ALLOWED_TOOLS"
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

# ---- Detached placement — a new workspace tab. ------------------------------
# --focus false, like every other creation verb here. `--focus true` is NOT required
# for a tty, whatever a stale comment or memory says: re-verified on cmux 0.64.22.
# `cmux send` is what attaches the PTY, lazily, on first send — a full claude TUI
# boots in a --focus false workspace, and focus only made the attachment eager at
# the cost of moving the user's cursor into the callee's shell mid-keystroke
# (claude-plugins-r465.4, r465.2).
#
# THE READINESS WAIT BELONGS TO THE FLAG. A wait that polls `cmux read-screen`
# until non-empty can NEVER succeed under --focus false: with no send yet there is
# no tty, and read-screen answers `Error: internal_error: Failed to read terminal
# text` every time — so such a loop burns its whole budget and then fires the launch
# command blind into an unattached surface, on every detached call. surface-ready.sh
# probes with a SEND instead, which is both the attachment step and the
# swallowed-`\n` check.
#
# Factored into a function so the side-by-side path can fall back to it when the
# caller's own surface context can't be resolved (see below). Sets SEND_TARGET.
do_detached() {
  local WS_NAME WS_OUTPUT WS_REF
  WS_NAME="${SESSION_NAME:-hotline}"
  if ! WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" --name "$WS_NAME" --focus false 2>&1); then
    fail_async "cmux new-workspace failed: $WS_OUTPUT"
  fi
  WS_REF=$(echo "$WS_OUTPUT" | grep -oE 'workspace:[0-9]+' | head -1 || true)
  [[ -z "$WS_REF" ]] && fail_async "cmux new-workspace failed: $WS_OUTPUT"
  echo "$WS_REF" > "$CALL_DIR/workspace_ref.txt"
  SEND_TARGET=(--workspace "$WS_REF")

  # Attach the PTY and prove the shell is executing input, before the launch
  # command goes anywhere near it. A timeout here is NOT fatal: the launch send
  # below can still attach and land, and the boot wait (wait-for-session.sh) is
  # what decides whether the callee came up. Recorded for diagnosis instead.
  if ! bash "$SCRIPT_DIR/surface-ready.sh" --workspace "$WS_REF" \
       --timeout "${HOTLINE_SURFACE_READY_TIMEOUT:-8}" \
       2>>"$CALL_DIR/surface_err.txt"; then
    echo "detached workspace $WS_REF never echoed the readiness probe; sending the launch command anyway" \
      >> "$CALL_DIR/surface_err.txt"
  fi
}

if [[ "$PLACEMENT" == "detached" ]]; then
  do_detached
else
  # ---- Surface placements: side-by-side (default) or a specific window. -----
  # Both open a VISIBLE terminal surface and wait until its PTY is attached and
  # the shell is executing input (--wait-ready) — the surface-mode equivalent
  # of `new-workspace --focus true`. This protects the fresh-PTY race (a
  # swallowed launch-command \n) and "Terminal surface not found" (PTY not yet
  # attached). On any readiness failure we close the surface we created rather
  # than leave a wedged surface behind.
  READY_TIMEOUT="${HOTLINE_SURFACE_READY_TIMEOUT:-8}"
  SURF_REF=""; SURF_ID=""; SURF_HANDLE=""; SURF_PANE=""; SURF_PANE_ID=""; SURF_PANE_HANDLE=""
  if [[ "$PLACEMENT" == "window" ]]; then
    # open-window-surface.sh is hotline-net-new (cmux-cli only opens side-by-side,
    # not arbitrary-window placement). It emits JSON even on a readiness timeout
    # (ready:"timeout"), exit 0.
    [[ -z "$WINDOW_REF" ]] && fail_async "--window requires a name or ref"
    SURF_JSON=$(bash "$SCRIPT_DIR/open-window-surface.sh" --window "$WINDOW_REF" \
      ${CWD:+--working-directory "$CWD"} --wait-ready --wait-ready-timeout "$READY_TIMEOUT" \
      --json 2>"$CALL_DIR/surface_err.txt") \
      || fail_async "open-window-surface.sh failed: $(cat "$CALL_DIR/surface_err.txt" 2>/dev/null)"
    SURF_REF=$(printf '%s' "$SURF_JSON" | jq -r '.surface_ref // empty')
    SURF_ID=$(printf '%s' "$SURF_JSON" | jq -r '.surface_id // empty')
    SURF_PANE=$(printf '%s' "$SURF_JSON" | jq -r '.pane_ref // empty')
    SURF_PANE_ID=$(printf '%s' "$SURF_JSON" | jq -r '.pane_id // empty')
    [[ -z "$SURF_REF" ]] && fail_async "open-window-surface returned no surface_ref: $SURF_JSON"
    if [[ "$(printf '%s' "$SURF_JSON" | jq -r '.ready // empty')" == "timeout" ]]; then
      cmux close-surface --surface "$SURF_REF" >/dev/null 2>&1 || true
      fail_async "surface $SURF_REF PTY never became ready (see surface_err.txt)"
    fi
  else
    # Side-by-side: cmux-cli's canonical opener. On a --wait-ready timeout it
    # exits 3 with NO JSON (the surface ref is named in its stderr diagnostic);
    # parse it so we can close the orphan rather than leak it.
    if SURF_JSON=$("$OPEN_SIDE_SURFACE" --caller --wait-ready \
        --wait-ready-timeout "$READY_TIMEOUT" --json 2>"$CALL_DIR/surface_err.txt"); then
      SURF_REF=$(printf '%s' "$SURF_JSON" | jq -r '.surface_ref // empty')
      SURF_ID=$(printf '%s' "$SURF_JSON" | jq -r '.surface_id // empty')
      SURF_PANE=$(printf '%s' "$SURF_JSON" | jq -r '.pane_ref // empty')
      SURF_PANE_ID=$(printf '%s' "$SURF_JSON" | jq -r '.pane_id // empty')
      [[ -z "$SURF_REF" ]] && fail_async "open-side-surface returned no surface_ref: $SURF_JSON"
    else
      rc=$?
      ORPHAN=$(grep -oE 'surface:[0-9]+' "$CALL_DIR/surface_err.txt" 2>/dev/null | head -1 || true)
      [[ -n "$ORPHAN" ]] && cmux close-surface --surface "$ORPHAN" >/dev/null 2>&1 || true
      SURF_ERR="$(cat "$CALL_DIR/surface_err.txt" 2>/dev/null)"
      if [[ "$rc" -eq 3 ]]; then
        fail_async "side-by-side surface PTY never became ready (see surface_err.txt)"
      elif [[ "$rc" -eq 2 && "$SURF_ERR" == *"could not resolve"*"from identify"* ]]; then
        # The caller's own surface context couldn't be resolved (open-side-surface
        # already retried `cmux identify` 5×). This happens when the caller pane was
        # freshly spawned or moved between workspaces and cmux hasn't re-registered
        # it. Side-by-side needs that context; detached does not (it opens its own
        # new workspace). Rather than fail the whole call, degrade to detached so the
        # dial still completes — the callee just lands in its own tab instead of a
        # sibling pane. surface_err.txt is preserved for diagnosis.
        PLACEMENT="detached"
        do_detached
      else
        fail_async "open-side-surface.sh failed (rc=$rc): $SURF_ERR"
      fi
    fi
  fi

  # If the side-by-side path fell back to detached above, do_detached already set
  # SEND_TARGET / workspace_ref.txt — skip the surface-mode bookkeeping (it would
  # clobber SEND_TARGET with an empty --surface ref).
  if [[ "$PLACEMENT" != "detached" ]]; then
    # Persist stable UUID handles when the opener provides them. Positional
    # surface:N / pane:N refs can retarget after tabs move or siblings close;
    # the file names stay for compatibility, but consumers treat their contents
    # as opaque cmux handles.
    SURF_HANDLE="${SURF_ID:-$SURF_REF}"
    SURF_PANE_HANDLE="${SURF_PANE_ID:-$SURF_PANE}"
    # surface_ref.txt is the cmux-SURFACE-mode signal to the wait-for-* scripts
    # (mirrors how workspace_ref.txt signals workspace mode). pane_ref.txt is
    # recorded for diagnosis and for a human who needs to find the pane. Nothing
    # reads it to force PTY attachment: a send attaches the PTY, and focus-pane
    # would attach it by moving the user's cursor into the callee.
    echo "$SURF_HANDLE" > "$CALL_DIR/surface_ref.txt"
    [[ -n "$SURF_PANE_HANDLE" ]] && echo "$SURF_PANE_HANDLE" > "$CALL_DIR/pane_ref.txt"
    SEND_TARGET=(--surface "$SURF_HANDLE")
    # Surface placements live in the caller's own window — keep them visible after
    # the call instead of auto-closing (the whole point is to SEE the call). The
    # caller closes the surface when done.
    KEEP_WORKSPACE=true
    echo "$KEEP_WORKSPACE" > "$CALL_DIR/keep_workspace.txt"
  fi
fi

# Fire the claude session into whichever surface/workspace we landed on.
#
# THE HANDLE IS CHECKED FIRST. `cmux send --surface ""` does not fail — it
# delivers to the FOCUSED surface, so an empty SEND_TARGET would type a claude
# launch command into whatever the user is looking at. Two real incidents on
# 2026-08-26 came from exactly that fallback (claude-plugins-r465.7).
if [[ ${#SEND_TARGET[@]} -ne 2 ]] || ! cmux_handle_ok "launch send" "${SEND_TARGET[1]}"; then
  fail_async "refusing to send the launch command: the ${PLACEMENT} placement produced no target handle, and cmux would deliver it to the focused surface"
fi

# Ctrl-U before the command. The surface's input line is shared with the user, and
# on 2026-08-26 three of their keystrokes arrived first: the shell ran
# `rkebash /tmp/hotline-launch-…`, printed `zsh: command not found: rkebash`, and
# the caller then spent its full 60s boot budget on a diagnostic that blamed
# --allowedTools. wait-for-session.sh now also fails fast on that error text.
cmux_clear_input_line "launch send" "${SEND_TARGET[0]}" "${SEND_TARGET[1]}"

if ! SEND_OUTPUT=$(cmux send "${SEND_TARGET[@]}" "bash $LAUNCH_SCRIPT\n" 2>&1); then
  if [[ "$PLACEMENT" == "detached" ]]; then
    [[ "$KEEP_WORKSPACE" != "true" ]] && \
      cmux close-workspace "${SEND_TARGET[@]}" 2>/dev/null || true
  fi
  fail_async "cmux send failed: $SEND_OUTPUT"
fi

jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
