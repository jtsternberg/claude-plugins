#!/usr/bin/env bash
# =============================================================================
# CMUX Call: Open a workspace in CMUX and launch Claude
#
# Usage:
#   cmux-call.sh --cwd <path> [--prompt <text>] [--resume <session-id>]
#
# Outputs: {"workspace_id": "...", "cwd": "...", "session_id": "..."}
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: cmux-call.sh --cwd <path> [--prompt <text>] [--resume <session-id>] [--name <name>] [--fork-session] [--tools <tools>]"
  echo ""
  echo "Opens a workspace in CMUX and launches Claude."
  echo "Outputs: {\"workspace_id\": \"...\", \"cwd\": \"...\", \"session_id\": \"...\"}"
  echo ""
  echo "  --prompt <text>  Optional prompt to deliver to the interactive session"
  echo "  --tools <tools>  Override allowed tools (default: \"Bash Read Edit Write Grep Glob\")"
  exit 0
fi

CWD=""
PROMPT=""
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
  [[ -z "$SURF_REF" ]] && { jq -n --arg e "surface opener returned no ref: $SURF_JSON" '{error: $e}'; exit 1; }
  SEND_TARGET=(--surface "$SURF_REF")
  PLACE_REF="$SURF_REF"; PLACE_KIND="surface"
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
  [[ -z "$SURF_REF" ]] && { jq -n --arg e "surface opener returned no ref: $SURF_JSON" '{error: $e}'; exit 1; }
  SEND_TARGET=(--surface "$SURF_REF")
  PLACE_REF="$SURF_REF"; PLACE_KIND="surface"
fi

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
  if [[ -n "$RESUME_ID" ]]; then
    printf ' --resume %q' "$RESUME_ID"
  elif [[ -n "$SESSION_ID_PRESET" ]]; then
    printf ' --session-id %q' "$SESSION_ID_PRESET"
  fi
  [[ -n "$SESSION_NAME" ]] && printf ' -n %q' "$SESSION_NAME"
  $FORK_SESSION && printf ' --fork-session'
  # Opt-in via HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS — see cmux-call-async.sh
  # for the rationale.
  case "${HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS:-}" in
    1|true|TRUE|yes|YES) printf ' --dangerously-skip-permissions' ;;
  esac
  printf ' --allowedTools %q' "$ALLOWED_TOOLS"
  # `--` is REQUIRED before the positional prompt because --allowedTools is
  # variadic (`<tools...>`) and would otherwise swallow the prompt as an
  # extra "tool" name. See cmux-call-async.sh for the live-reproduced bug.
  [[ -n "$PROMPT" ]] && printf ' -- %q' "$PROMPT"
  printf '\n'
} > "$LAUNCH_SCRIPT"

if ! cmux send "${SEND_TARGET[@]}" "bash $LAUNCH_SCRIPT\n"; then
  rm -f "$LAUNCH_SCRIPT"
  jq -n --arg err "cmux send failed" '{error: $err}'
  exit 1
fi

# Emit both workspace_ref and surface_ref keys (one null) so callers can read
# whichever they need. workspace_ref stays populated in detached mode for
# backward compatibility; surface placements populate surface_ref instead.
WS_OUT=""; SURF_OUT=""
if [[ "$PLACE_KIND" == "surface" ]]; then SURF_OUT="$PLACE_REF"; else WS_OUT="$PLACE_REF"; fi
jq -n --arg ws "$WS_OUT" --arg surf "$SURF_OUT" --arg cwd "$CWD" \
  --arg sid "${SESSION_ID_PRESET:-new}" --arg kind "$PLACE_KIND" \
  '{workspace_ref: (if $ws == "" then null else $ws end),
    surface_ref:   (if $surf == "" then null else $surf end),
    placement: $kind, cwd: $cwd, session_id: $sid,
    message: "CMUX \($kind) opened with Claude session"}'
