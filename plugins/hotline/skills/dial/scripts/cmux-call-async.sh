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
#   transport.txt        — 'cmux'. The explicit backend signal the wait-for-*
#                          scripts read first; coarse (it names the backend, not the
#                          sub-mode), so placement.txt below picks the cmux one.
#   placement.txt        — 'side' | 'detached' | 'window': which cmux placement
#                          HOSTS this call, written once the placement is FINAL
#                          (so a side-by-side that degraded reads 'detached').
#                          This is the sub-mode signal — which host the waiters
#                          poll, and which verb closes it. It used to be inferred
#                          from which ref file existed, which meant a detached
#                          call could not record its surface without being read
#                          as a side placement (claude-plugins-zaus). Read via
#                          call_dir_placement (scripts/transport.sh).
#   degraded.txt         — present only when side-by-side degraded to detached
#                          because the caller's own surface context was
#                          unresolvable; holds the fallback name dial.sh records.
#   workspace_ref.txt    — the cmux workspace ref, for a DETACHED call: the tab
#                          the callee lives in, and what its cleanup closes.
#   workspace_id.txt     — that workspace as a UUID, for calls that must scope a
#                          close (`cmux close-surface` needs --workspace).
#   surface_ref.txt      — the surface UUID hosting the callee's REPL. Present
#                          for EVERY placement that resolved one, detached
#                          included: it is the handle a follow-up re-addresses
#                          instead of opening another tab.
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
#                      [--resume <id>] [--name <name>] [--label <text>]
#                      [--fork-session] [--tools <list>] [--keep-workspace]
#   # Returns immediately with: {"call_dir": "/tmp/hotline-call-xxxxx"}
#
# --prompt-file is preferred: it keeps the payload out of argv end to end.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: cmux-call-async.sh --cwd <path> --prompt <text> [--resume <id>]
                          [--name <name>] [--label <text>] [--fork-session]
                          [--tools <list>] [--keep-workspace]

Opens an interactive claude session in a cmux workspace and returns immediately
with {"call_dir": "/tmp/hotline-call-XXXXX"}. The caller then drives polling
via wait-for-session.sh and wait-for-response.sh — those scripts read
placement.txt from the call_dir to learn which cmux host this call landed on,
and poll that surface or workspace screen directly (they retain cmux ancestry,
this script's background subshell would not).

Options:
  --label <text>     What the callee is DOING. Used as the workspace name for
                     --detached; a surface placement reads it off --name, which
                     claude emits as its own live terminal title.
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
# What the callee is DOING. A SURFACE placement needs nothing from it: SESSION_NAME
# carries the same label and claude publishes that as its terminal title, which cmux
# renders live in the tab strip. A DETACHED callee has no such tab of its own — it
# gets a workspace, whose name is what the strip shows — so this is what names it.
LABEL=""
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
    --label)          LABEL="$2";          shift 2 ;;
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

# HOTLINE_CALLEE_ENV rides the callee's argv as a settings env block — see
# scripts/callee-env.sh. dial.sh refuses a malformed value at its args stage; this
# repeats the check for a direct invocation rather than launching without it.
source "$SCRIPT_DIR/../../../scripts/callee-env.sh"
callee_env_validate || { jq -nc --arg e "HOTLINE_CALLEE_ENV: $CALLEE_ENV_ERR" '{error: $e}'; exit 1; }
CALLEE_SETTINGS=$(callee_env_settings_json)

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
# Which backend owns this call dir. Written here, with the dir, so it is present
# for every later reader no matter where this launcher gets to — the host handle
# (surface_ref.txt / workspace_ref.txt) is not placed until much further down.
# Coarse selector only: it names cmux, not which cmux sub-mode. See
# wait-for-session.sh's dispatch block for the whole contract.
echo cmux > "$CALL_DIR/transport.txt"
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
  # Callee system-prompt override, baked in the same way. The FILE form, never
  # the raw --append-system-prompt string: a multi-line prompt on argv is
  # readable via `ps`, the leak the work-order payload is kept off argv to avoid.
  [[ -n "${HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE:-}" ]] && \
    printf ' --append-system-prompt-file %q' "$HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE"
  [[ -n "$CALLEE_SETTINGS" ]] && printf ' --settings %q' "$CALLEE_SETTINGS"
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
  # A detached callee's workspace name IS what the user reads in the tab strip, so
  # the label goes there. Prefixed, not bare: `--window <name>` resolves a window by
  # the title of a workspace inside it (open-window-surface.sh), so a workspace
  # titled with a bare subject could be picked up as a `--window` target by a later
  # dial.
  WS_NAME="${LABEL:+hotline: $LABEL}"
  WS_NAME="${WS_NAME:-${SESSION_NAME:-hotline}}"
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

  # ---- Which surface is in there, so a follow-up can re-address it -----------
  # A detached callee lives in exactly ONE surface, and nothing used to record
  # which: the call dir held only the workspace ref, so register-call.sh cached no
  # surface handle and every follow-up recorded
  # `surface-reuse-skipped(no-cached-surface)` and opened another tab
  # (claude-plugins-zaus). placement.txt is what now tells the waiters this is
  # still a DETACHED call, so recording a surface here no longer implies one.
  #
  # THE UUID, never the positional ref, and resolved after `new-workspace` has
  # returned rather than guessed from its output: `surface:N` names whatever
  # currently sits in slot N, slots renumber when tabs move or siblings close, and
  # this handle is read on a LATER turn — precisely when that has happened.
  #
  # Best effort by design. The workspace and its PTY are already up, so a tree
  # that cannot be read costs a follow-up its reuse — the behaviour every detached
  # call had until now — and must not fail a call that otherwise succeeded. The
  # `|| true` is required rather than defensive: under `set -e` a resolver that
  # finds nothing would abort the launcher here instead of letting the call
  # proceed without the handle (docs/compounding.md, the read-guard entry).
  local WS_ADDR
  WS_ADDR=$(cmux_workspace_current_surface "$WS_REF" || true)
  if [[ -n "$WS_ADDR" ]]; then
    echo "${WS_ADDR##* }" > "$CALL_DIR/surface_ref.txt"
    # The workspace as a UUID. `cmux close-surface` needs --workspace and a
    # positional workspace ref renumbers the same way a surface ref does, so the
    # cleanup path gets the id, not the `workspace:N` above.
    echo "${WS_ADDR%% *}" > "$CALL_DIR/workspace_id.txt"
  else
    echo "could not resolve the surface inside detached workspace $WS_REF from the cmux tree; a follow-up will open a fresh tab rather than reuse this one" \
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
      # Reap the surface we just opened: its PTY never attached, so nothing can
      # use it and the call is about to fail. --workspace is not optional — see
      # cmux_close_surface_scoped — and a close that fails is RECORDED rather
      # than swallowed, because a silent no-op here leaks a wedged surface into
      # the user's window with no trace of why (claude-plugins-5k43). Prefer the
      # UUID the opener gave us; its positional ref is the fallback.
      if ! cmux_close_surface_scoped "unready window surface" "${SURF_ID:-$SURF_REF}"; then
        echo "failed to close the unready surface ${SURF_ID:-$SURF_REF}: $CMUX_CLOSE_ERR" \
          >> "$CALL_DIR/surface_err.txt"
      fi
      fail_async "surface $SURF_REF PTY never became ready (see surface_err.txt)"
    fi
  else
    # Side-by-side: cmux-cli's canonical opener. On a --wait-ready timeout it
    # exits 3 with NO JSON (the surface ref is named in its stderr diagnostic);
    # parse it so we can close the orphan rather than leak it.
    # NO --title, deliberately. The opener would apply it with `cmux rename-tab`,
    # which PINS a static title over claude's own dynamic one for the life of the
    # tab — costing the ◑/✳/⏺ activity glyph that is how a stuck callee is spotted.
    # The tab already reads the label: SESSION_NAME goes to `claude -n`, claude
    # publishes it as the terminal title, and cmux renders that live. The opener
    # prints a hint to stderr about the absent --title; it lands in surface_err.txt
    # and is expected there.
    if SURF_JSON=$("$OPEN_SIDE_SURFACE" --caller --wait-ready \
        --wait-ready-timeout "$READY_TIMEOUT" --json 2>"$CALL_DIR/surface_err.txt"); then
      SURF_REF=$(printf '%s' "$SURF_JSON" | jq -r '.surface_ref // empty')
      SURF_ID=$(printf '%s' "$SURF_JSON" | jq -r '.surface_id // empty')
      SURF_PANE=$(printf '%s' "$SURF_JSON" | jq -r '.pane_ref // empty')
      SURF_PANE_ID=$(printf '%s' "$SURF_JSON" | jq -r '.pane_id // empty')
      # WHAT THIS GUARD IS FOR: having nothing to address the callee by. It used to
      # test SURF_REF alone while SURF_HANDLE below prefers SURF_ID — so the field
      # everything downstream actually uses was never checked, and the one that was
      # checked is the one that renumbers.
      #
      # Both empty is the real failure: no handle, so nothing can be sent, read or
      # closed.
      if [[ -z "$SURF_ID" && -z "$SURF_REF" ]]; then
        fail_async "open-side-surface returned neither a surface_id nor a surface_ref, so there is no handle to address the callee by. Opener: ${OPEN_SIDE_SURFACE:-<unresolved>}. Payload: $SURF_JSON"
      fi
      # A UUID ALONE IS NOT REQUIRED, deliberately. cmux-cli and hotline ship as
      # separate plugins on independent versions, and an opener released before the
      # UUID became mandatory degrades to the positional ref with null ids. Hard-
      # failing here would break a hotline upgrade on an un-upgraded sibling plugin,
      # and nothing anywhere declares "hotline needs cmux-cli >= X" — so the ref is
      # accepted and the degrade is RECORDED instead of silently taken.
      #
      # surface_err.txt is where it goes because that is the file a failed dial is
      # diagnosed from: dial.sh surfaces it, the orphan-reap path greps it, and it
      # is already the opener's own stderr sink. A caller debugging a send that went
      # to the wrong pane needs to know the handle was positional, and a ref is
      # exactly what renumbers when a sibling closes or a surface moves.
      if [[ -z "$SURF_ID" ]]; then
        {
          echo "DEGRADED HANDLE: open-side-surface returned the positional ref $SURF_REF and no surface_id, so this callee is addressed by a ref rather than a UUID."
          echo "  A ref names whatever occupies that slot when a later call runs — it renumbers when a sibling surface closes or moves — so a send, read or close on it can land on the wrong surface."
          echo "  Opener: ${OPEN_SIDE_SURFACE:-<unresolved>}"
          echo "  Fix: update the cmux-cli plugin. A current opener resolves the UUID (retrying, since a fresh surface is not instantly enumerable) or exits 4 rather than reporting a null."
        } >> "$CALL_DIR/surface_err.txt"
      fi
    else
      rc=$?
      # The opener named the surface it had already created in its stderr, so
      # there is one to reap — but ONLY BY UUID. Resolving a positional
      # `surface:N` through the tree does not make the ref correct; it makes the
      # close land on whatever occupies slot N at lookup time, and the window
      # between the opener minting that ref and this reap is the whole readiness
      # probe (HOTLINE_SURFACE_READY_TIMEOUT, 8s by default) — long enough for a
      # sibling to close and renumber it onto a live tab. The old unscoped close
      # merely no-op'd; a scoped one would succeed on the wrong surface, so a ref
      # is no longer something to act on.
      #
      # The opener prints `surface_id=<uuid>` in the same diagnostic for exactly
      # this. The close still resolves it through the tree, because
      # `cmux close-surface` needs --workspace as well (claude-plugins-5k43).
      # Recorded either way, never swallowed — a skipped reap leaks a wedged
      # surface, which is worth the same trace as a failed one.
      ORPHAN_ID=$(grep -oE 'surface_id=[0-9A-Za-z-]+' "$CALL_DIR/surface_err.txt" 2>/dev/null \
        | head -1 | cut -d= -f2 || true)
      ORPHAN=$(grep -oE 'surface:[0-9]+' "$CALL_DIR/surface_err.txt" 2>/dev/null | head -1 || true)
      if [[ -n "$ORPHAN_ID" ]]; then
        if ! cmux_close_surface_scoped "orphan side surface" "$ORPHAN_ID"; then
          echo "failed to close the orphan surface $ORPHAN_ID: $CMUX_CLOSE_ERR" \
            >> "$CALL_DIR/surface_err.txt"
        fi
      elif [[ -n "$ORPHAN" ]]; then
        echo "NOT reaping orphan surface $ORPHAN: the opener named it only by positional ref, which points at whatever occupies that slot now rather than at the surface it opened. Close it by hand — \`cmux tree --all --json --id-format both\` will say which UUID it is." \
          >> "$CALL_DIR/surface_err.txt"
      elif [[ ! -s "$CALL_DIR/surface_err.txt" ]]; then
        # The opener exited reporting NOTHING — a shell-level abort, not
        # something cmux refused. Neither grep above can find a UUID to reap or
        # a positional ref to refuse, but the opener may still have created a
        # surface before dying: it hadn't reached the point of exec'ing claude
        # into it, so it carries no `hotline:` session title, just the shell's
        # own generic one. Named here (not just closed) because there is no
        # UUID to close it BY — see the positional-ref refusal above.
        echo "opener exited (rc=$rc) with no diagnostic at all, before printing a surface_id — it may have created a surface before dying, left with a generic shell title (no \`hotline:\` name) and no UUID recorded to close it by. Find it by hand: \`cmux tree --all --json --id-format both\`, then close whichever surface in this workspace still shows a plain shell prompt." \
          >> "$CALL_DIR/surface_err.txt"
      fi
      SURF_ERR="$(cat "$CALL_DIR/surface_err.txt" 2>/dev/null)"
      if [[ "$rc" -eq 3 ]]; then
        fail_async "side-by-side surface PTY never became ready (see surface_err.txt)"
      elif [[ "$rc" -eq 2 && "$SURF_ERR" == *"could not resolve"*"from identify"* ]] \
        || [[ "$rc" -eq 1 && "$SURF_ERR" == *"not_found"* ]]; then
        # The caller's own surface context is unusable for side-by-side placement.
        # Two shapes of the same problem:
        #   rc=2 — `cmux identify` never resolved the caller's pane/workspace
        #     (retried 5×); the caller pane was freshly spawned or moved and cmux
        #     hasn't re-registered it.
        #   rc=1 + not_found — the context resolved, but cmux then refused the
        #     target. The opener pins --workspace/--window on every new-surface
        #     call, so this means the pane or its workspace changed between the
        #     opener's tree snapshot and the call — a safety net, not an
        #     expected path (claude-plugins-qyj1).
        # Side-by-side needs that context; detached does not (it opens its own
        # new workspace). Rather than fail the whole call, degrade to detached so the
        # dial still completes — the callee just lands in its own tab instead of a
        # sibling pane. surface_err.txt is preserved for diagnosis, and degraded.txt
        # below is what dial.sh reads to record the `surface-context→detached`
        # fallback, so nothing is silent.
        #
        # AN EXPLICIT MARKER, not the shape of the call dir. dial.sh used to infer
        # this degrade from `workspace_ref.txt && ! surface_ref.txt`, which made the
        # absence of a surface handle carry two meanings at once — and a detached
        # callee cannot record the surface a follow-up needs while its absence is
        # also the degrade signal (claude-plugins-zaus).
        PLACEMENT="detached"
        echo "surface-context→detached" > "$CALL_DIR/degraded.txt"
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
    # surface_ref.txt is the handle of the surface hosting the callee's REPL — what
    # the waiters poll and what a follow-up re-addresses. It is NOT the surface-mode
    # signal any more: placement.txt is (a detached call records a surface too).
    # pane_ref.txt is recorded for diagnosis and for a human who needs to find the
    # pane. Nothing reads it to force PTY attachment: a send attaches the PTY, and
    # focus-pane would attach it by moving the user's cursor into the callee.
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

# ---- Which placement actually hosts this call ------------------------------
# HERE, not at argument-parsing time: $PLACEMENT is only final once the degrade
# above has or has not fired, and the waiters need the placement that HAPPENED.
# 'sidebyside' is this script's internal spelling; 'side' is the word dial.sh
# emits as `.placement` and the one call_dir_placement knows, so one vocabulary
# reaches every reader. See scripts/transport.sh for what reads it.
case "$PLACEMENT" in
  sidebyside) echo side     > "$CALL_DIR/placement.txt" ;;
  *)          echo "$PLACEMENT" > "$CALL_DIR/placement.txt" ;;
esac

# Fire the claude session into whichever surface/workspace we landed on.
#
# THE HANDLE IS CHECKED FIRST. `cmux send --surface ""` does not fail — it
# falls back to the inherited $CMUX_*_ID, so an empty SEND_TARGET would type a claude
# launch command into whatever the user is looking at. Two real incidents on
# 2026-08-26 came from exactly that fallback (claude-plugins-r465.7).
if [[ ${#SEND_TARGET[@]} -ne 2 ]] || ! cmux_handle_ok "launch send" "${SEND_TARGET[1]}"; then
  fail_async "refusing to send the launch command: the ${PLACEMENT} placement produced no target handle, and cmux would fall back to \$CMUX_*_ID and deliver it to THIS pane"
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
