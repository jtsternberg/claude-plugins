#!/usr/bin/env bash
# =============================================================================
# CMUX Call: Open a workspace in CMUX and launch Claude
#
# The synchronous sibling of cmux-call-async.sh, used by conference mode: the
# session is handed to the user in a visible surface and nobody polls for a
# response, so this script does the whole job in one go.
#
# THE PROMPT IS NOT LAUNCHED WITH CLAUDE. Like cmux-call-async.sh, this starts a
# BARE claude REPL and then delivers the prompt with one `terminal.paste` over
# cmux's control socket (cmux-paste.sh). It used to pass the prompt as claude's
# positional argument, which published whole work orders to `ps` for every local
# user (claude-plugins-86ka, claude-plugins-92s5). Conference was the last path
# still doing that.
#
# Being synchronous, this script owns the boot wait too — cmux-paste.sh --wait-box
# blocks until the REPL has drawn its input box, because a payload delivered to a
# surface that has not exec'd claude goes to the shell, which would RUN it.
#
# It also mints a per-call nonce now. Conference calls previously had none, so the
# receiver had no call_id to echo and superseded-surface cleanup could never prove
# a conference surface's identity. The nonce is returned as .call_id.
#
# Usage:
#   cmux-call.sh --cwd <path> [--prompt <text> | --prompt-file <path>]
#                [--resume <session-id>] [--name <name>] [--fork-session]
#                [--tools <tools>] [--detached | --window <name|ref>]
#
# Outputs: {"workspace_ref"|"surface_ref", "surface_id", "placement", "cwd",
#           "session_id", "call_id"}
#   # → {"error": "...", "undelivered": true}  the REPL is up but the prompt
#   #   never landed; .prompt_file still holds it.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: cmux-call.sh --cwd <path> [--prompt <text>] [--resume <session-id>] [--name <name>] [--fork-session] [--tools <tools>]"
  echo ""
  echo "Opens a workspace in CMUX and launches Claude."
  echo "Outputs: {\"workspace_id\": \"...\", \"cwd\": \"...\", \"session_id\": \"...\"}"
  echo ""
  echo "  --prompt <text>       Optional prompt to deliver to the interactive session"
  echo "  --prompt-file <path>  Same, read from a file (preferred: keeps it off argv)"
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
# Placement (see cmux-call-async.sh for the full rationale):
#   sidebyside (default) — visible surface next to the caller, SAME window.
#   detached             — original behavior: a new-workspace tab.
#   window               — a surface in a specific window (find-or-create).
PLACEMENT="sidebyside"
WINDOW_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    --name) SESSION_NAME="$2"; shift 2 ;;
    --fork-session) FORK_SESSION=true; shift ;;
    --tools) ALLOWED_TOOLS="$2"; shift 2 ;;
    --detached|--new-workspace) PLACEMENT="detached"; shift ;;
    --window) PLACEMENT="window"; WINDOW_REF="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$CWD" ]]; then
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

# --fork-session COPIES the resumed session's transcript into a new id. With no
# --resume target there is nothing to copy, so claude forks an EMPTY session — the
# call appears to succeed but the receiver reports "fresh session, nothing run here".
# In hotline usage --fork-session is only ever valid alongside --resume, so refuse
# the combination instead of silently forking nothing.
if $FORK_SESSION && [[ -z "$RESUME_ID" ]]; then
  echo '{"error": "--fork-session requires --resume <id>; forking with no resume target silently creates an empty session"}'
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tree reading (and the input-box judgement) live in one place.
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

# Side-by-side delegates to cmux-cli's canonical open-side-surface.sh (single
# source of truth — no vendored copy). cmux can be present without the cmux-cli
# plugin; when the opener won't resolve, signal the dial skill to fall back to
# the HEADLESS transport. (--detached / --window don't need the opener.)
OPEN_SIDE_SURFACE=""
if [[ "$PLACEMENT" == "sidebyside" ]]; then
  if ! OPEN_SIDE_SURFACE=$(bash "$SCRIPT_DIR/resolve-side-opener.sh" 2>/dev/null); then
    jq -n '{fallback: "headless", reason: "cmux-cli open-side-surface.sh not found; side-by-side placement unavailable"}'
    exit 0
  fi
fi

# Decide where the conference surface lands. SEND_TARGET is the cmux send/output
# target; PLACE_REF + PLACE_KIND describe it for the returned JSON.
SEND_TARGET=()
PLACE_REF=""
PLACE_ID=""
PLACE_KIND=""
if [[ "$PLACEMENT" == "detached" ]]; then
  # --focus true is REQUIRED: without it cmux does not spawn a real tty for the
  # workspace's terminal surface, and subsequent `cmux send` calls fail with
  # "Terminal surface not found". Discovered via live testing.
  WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" --focus true 2>&1)
  WS_REF=$(echo "$WS_OUTPUT" | grep -oE 'workspace:[0-9]+' | head -1 || true)
  if [[ -z "$WS_REF" ]]; then
    jq -n --arg err "cmux new-workspace failed: $WS_OUTPUT" '{error: $err}'
    exit 1
  fi
  SEND_TARGET=(--workspace "$WS_REF")
  PLACE_REF="$WS_REF"; PLACE_KIND="workspace"
elif [[ "$PLACEMENT" == "window" ]]; then
  # Surface placement in a specific window (hotline-net-new opener). --wait-ready
  # is the surface-mode equivalent of `new-workspace --focus true`.
  READY_TIMEOUT="${HOTLINE_SURFACE_READY_TIMEOUT:-8}"
  [[ -z "$WINDOW_REF" ]] && { jq -n '{error: "--window requires a name or ref"}'; exit 1; }
  SURF_JSON=$(bash "$SCRIPT_DIR/open-window-surface.sh" --window "$WINDOW_REF" \
    ${CWD:+--working-directory "$CWD"} --wait-ready --wait-ready-timeout "$READY_TIMEOUT" --json 2>&1) \
    || { jq -n --arg e "open-window-surface failed: $SURF_JSON" '{error: $e}'; exit 1; }
  SURF_REF=$(printf '%s' "$SURF_JSON" | jq -r '.surface_ref // empty')
  SURF_ID=$(printf '%s' "$SURF_JSON" | jq -r '.surface_id // empty')
  [[ -z "$SURF_REF" ]] && { jq -n --arg e "surface opener returned no ref: $SURF_JSON" '{error: $e}'; exit 1; }
  SEND_TARGET=(--surface "${SURF_ID:-$SURF_REF}")
  PLACE_REF="$SURF_REF"; PLACE_ID="$SURF_ID"; PLACE_KIND="surface"
else
  # Side-by-side via cmux-cli's canonical opener. On a --wait-ready timeout it
  # exits 3 (no JSON); surface its stderr as the error.
  READY_TIMEOUT="${HOTLINE_SURFACE_READY_TIMEOUT:-8}"
  if ! SURF_JSON=$("$OPEN_SIDE_SURFACE" --caller --wait-ready \
      --wait-ready-timeout "$READY_TIMEOUT" --json 2>/tmp/hotline-side-err.$$); then
    err=$(cat /tmp/hotline-side-err.$$ 2>/dev/null); rm -f /tmp/hotline-side-err.$$
    jq -n --arg e "open-side-surface failed: $err" '{error: $e}'; exit 1
  fi
  rm -f /tmp/hotline-side-err.$$
  SURF_REF=$(printf '%s' "$SURF_JSON" | jq -r '.surface_ref // empty')
  SURF_ID=$(printf '%s' "$SURF_JSON" | jq -r '.surface_id // empty')
  [[ -z "$SURF_REF" ]] && { jq -n --arg e "surface opener returned no ref: $SURF_JSON" '{error: $e}'; exit 1; }
  SEND_TARGET=(--surface "${SURF_ID:-$SURF_REF}")
  PLACE_REF="$SURF_REF"; PLACE_ID="$SURF_ID"; PLACE_KIND="surface"
fi

# Session ID for the callee. See cmux-call-async.sh for the full rationale:
# cmux mode can't read the real ID back from structured output, so the ID we
# record here is authoritative. A FORK writes to a new session, so the resume
# target is NOT it — generate a fresh ID and hand it to claude via --session-id.
# Plain resume keeps its own ID and rejects --session-id outright ("--session-id
# can only be used with --continue or --resume if --fork-session is also
# specified"). PRESET_IS_OURS distinguishes the two below.
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

# Per-call nonce, and it goes INTO the prompt. Inline after a slash command, not on
# a leading line of its own: claude parses a slash command only at the very start
# of the input, so a header above `/hotline:hotline-ringing` would turn the whole
# invocation into plain text. Same rule as cmux-call-async.sh.
CALL_ID=$(
  openssl rand -hex 8 2>/dev/null \
  || od -A n -N 8 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n' \
  || date +%s%N | sha256sum 2>/dev/null | cut -c1-16
)
if [[ -n "$PROMPT" ]]; then
  if [[ "$PROMPT" == /* ]]; then
    CMD_TOKEN="${PROMPT%% *}"
    REST="${PROMPT#* }"
    if [[ "$CMD_TOKEN" == "$PROMPT" ]]; then
      PROMPT="$CMD_TOKEN [CALL_ID: $CALL_ID]"
    else
      PROMPT="$CMD_TOKEN [CALL_ID: $CALL_ID] $REST"
    fi
  else
    PROMPT="[CALL_ID: $CALL_ID] $PROMPT"
  fi
fi

LAUNCH_SCRIPT=$(mktemp /tmp/hotline-cmux-launch-XXXXX)
chmod 700 "$LAUNCH_SCRIPT"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cleanup() { rm -f "$0"; }\n'
  printf 'trap cleanup EXIT\n'
  # Surface placements inherit the caller's shell cwd — cd into the target dir
  # so the callee resolves files / cwd-matched --resume sessions correctly.
  [[ -n "$CWD" ]] && printf 'cd %q || exit 1\n' "$CWD"
  printf 'claude'
  # Model override, baked in at write time from the caller's env.
  [[ -n "${HOTLINE_CLAUDE_MODEL:-}" ]] && printf ' --model %q' "$HOTLINE_CLAUDE_MODEL"
  [[ -n "$RESUME_ID" ]] && printf ' --resume %q' "$RESUME_ID"
  # --session-id only when the preset is OURS (first contact or fork).
  $PRESET_IS_OURS && [[ -n "$SESSION_ID_PRESET" ]] && \
    printf ' --session-id %q' "$SESSION_ID_PRESET"
  [[ -n "$SESSION_NAME" ]] && printf ' -n %q' "$SESSION_NAME"
  $FORK_SESSION && printf ' --fork-session'
  # Opt-in via HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS — see cmux-call-async.sh
  # for the rationale.
  case "${HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS:-}" in
    1|true|TRUE|yes|YES) printf ' --dangerously-skip-permissions' ;;
  esac
  # `=`-joined into ONE argv word, not two. See cmux-call-async.sh for why the
  # two-token `--allowedTools <list>` form breaks `cmux restore claude`.
  # No positional prompt follows, so no `--` separator is needed either: the REPL
  # comes up empty and the prompt is pasted in below.
  printf ' --allowedTools=%q' "$ALLOWED_TOOLS"
  printf '\n'
} > "$LAUNCH_SCRIPT"

# CAPTURED, not left to leak. `cmux send` prints "OK surface:N workspace:N" on
# stdout, and this script's stdout is a single JSON object its caller parses with
# jq — so an unredirected send prepended a non-JSON line to the payload and every
# `jq -r '.session_id'` in dial.sh's conference branch came back empty. Found by
# running the real thing (the suite's `send` stub writes to a file, so no stub
# would ever have shown it). Capturing also gives the failure path a real
# diagnostic instead of a bare "cmux send failed".
if ! SEND_OUTPUT=$(cmux send "${SEND_TARGET[@]}" "bash $LAUNCH_SCRIPT\n" 2>&1); then
  rm -f "$LAUNCH_SCRIPT"
  jq -n --arg err "cmux send failed: $(printf '%s' "$SEND_OUTPUT" | tr '\n\r\t' '   ' | cut -c1-160)" \
    '{error: $err}'
  exit 1
fi

# --- Deliver the prompt into the REPL that is now booting --------------------
# Same verb as every other hotline delivery. Synchronous here: nobody polls a
# conference call, so if this script returned before the prompt landed there would
# be no second chance to notice.
if [[ -n "$PROMPT" ]]; then
  PASTE_PROMPT=$(mktemp /tmp/hotline-conf-prompt-XXXXX)
  chmod 600 "$PASTE_PROMPT"
  printf '%s' "$PROMPT" > "$PASTE_PROMPT"

  # Which surface? A surface placement already knows. The detached placement named
  # a workspace, so its surface comes out of the shared tree reader.
  PASTE_SURFACE="$PLACE_ID"
  PASTE_WORKSPACE=""
  if [[ "$PLACE_KIND" == "workspace" ]]; then
    if CONF_ADDR=$(cmux_workspace_current_surface "$PLACE_REF"); then
      PASTE_WORKSPACE="${CONF_ADDR%% *}"
      PASTE_SURFACE="${CONF_ADDR##* }"
    fi
  fi
  if [[ -z "$PASTE_SURFACE" ]]; then
    jq -n --arg err "the conference REPL was launched but no surface could be resolved to paste the prompt into (placement $PLACE_KIND $PLACE_REF)" \
          --arg pf "$PASTE_PROMPT" \
      '{error: $err, undelivered: true, prompt_file: $pf}'
    exit 1
  fi

  CONF_PASTE_ARGS=(--surface "$PASTE_SURFACE" --payload-file "$PASTE_PROMPT"
                   --call-id "$CALL_ID" --cwd "$CWD"
                   --wait-box "${HOTLINE_PASTE_BOX_TIMEOUT:-20}")
  [[ -n "$PASTE_WORKSPACE"    ]] && CONF_PASTE_ARGS+=(--workspace "$PASTE_WORKSPACE")
  [[ -n "$SESSION_ID_PRESET"  ]] && CONF_PASTE_ARGS+=(--session "$SESSION_ID_PRESET")
  CONF_DELIVERY=$(bash "$SCRIPT_DIR/cmux-paste.sh" "${CONF_PASTE_ARGS[@]}" 2>/dev/null)
  if [[ "$(jq -r '.delivered // false' <<<"$CONF_DELIVERY" 2>/dev/null)" != "true" ]]; then
    # The surface stays open: its REPL is live, and the prompt file is left behind
    # so a human (or the caller) can still deliver it.
    jq -n --arg err "the conference REPL booted but the prompt never landed in it: $(jq -r '.reason // "no reason given"' <<<"$CONF_DELIVERY" 2>/dev/null | tr '\n\r\t' '   ' | cut -c1-200)" \
          --arg pf "$PASTE_PROMPT" \
      '{error: $err, undelivered: true, prompt_file: $pf}'
    exit 1
  fi
  # Delivered and confirmed — the callee's transcript is the record now.
  rm -f "$PASTE_PROMPT"
fi

# Register the call in the sessions registry (script-level — conference mode
# has no call_dir/wait-for-session flow, so registration happens right here).
# Best-effort: skipped silently when the prompt lacks ringing tags.
EFFECTIVE_SID="${RESUME_ID:-$SESSION_ID_PRESET}"
if [[ -n "$EFFECTIVE_SID" && -n "$PROMPT" ]]; then
  REG_MODE=$(sed -n 's/.*\[MODE: \([a-z_]*\)\].*/\1/p' <<<"$PROMPT" | head -1)
  REG_CALLER_SESSION=$(sed -n 's/.*\[SESSION: \([^]]*\)\].*/\1/p' <<<"$PROMPT" | head -1)
  if [[ -n "$REG_MODE" && -n "$REG_CALLER_SESSION" ]]; then
    bash "$(dirname "${BASH_SOURCE[0]}")/session-cache.sh" set "$CWD" \
      --caller-session "$REG_CALLER_SESSION" --session "$EFFECTIVE_SID" \
      --mode "$REG_MODE" >/dev/null 2>&1 || true
  fi
fi

# Emit both workspace_ref and surface_ref keys (one null) so callers can read
# whichever they need. workspace_ref stays populated in detached mode for
# backward compatibility; surface placements populate surface_ref instead.
WS_OUT=""; SURF_OUT=""
if [[ "$PLACE_KIND" == "surface" ]]; then SURF_OUT="$PLACE_REF"; else WS_OUT="$PLACE_REF"; fi
jq -n --arg ws "$WS_OUT" --arg surf "$SURF_OUT" --arg surf_id "$PLACE_ID" --arg cwd "$CWD" \
  --arg sid "${SESSION_ID_PRESET:-new}" --arg kind "$PLACE_KIND" --arg cid "$CALL_ID" \
  '{workspace_ref: (if $ws == "" then null else $ws end),
    surface_ref:   (if $surf == "" then null else $surf end),
    surface_id:    (if $surf_id == "" then null else $surf_id end),
    placement: $kind, cwd: $cwd, session_id: $sid, call_id: $cid,
    message: "CMUX \($kind) opened with Claude session"}'
