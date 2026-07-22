#!/usr/bin/env bash
# =============================================================================
# CMUX Reuse Surface: send a follow-up INTO the surface a session already lives
# in, instead of opening a new one.
#
# On first contact a cmux call lands the callee's claude session in a visible
# side-by-side (or windowed) surface and leaves it open. That surface holds a
# LIVE, idle claude REPL for that exact session. So a follow-up doesn't need to
# `claude --resume` in a fresh surface (which stacks N surfaces over N turns) —
# it just types the next message into the REPL that's already sitting there.
#
# This script:
#   1. Verifies the stored surface still exists (the user may have closed it).
#   2. Types the raw message (prefixed with a fresh [CALL_ID:] nonce) into it.
#   3. Returns a call_dir wired exactly like cmux-call-async.sh's surface mode,
#      so wait-for-response.sh polls THIS surface and — thanks to the fresh
#      nonce — ignores the prior exchange's stale STATUS lines in scrollback.
#
# If the surface is gone, emits {"fallback":"fresh"} so the caller falls back to
# opening a new surface via cmux-call-async.sh --resume (the pre-reuse path).
#
# No --resume / no relaunch: the live REPL IS the session. Re-launching claude
# inside it would nest a second REPL.
#
# Usage:
#   cmux-reuse-surface.sh --surface <ref> --session <id> --prompt <text>
#                         [--keep-workspace]
#   # → {"call_dir": "/tmp/hotline-call-XXXXX"}   (reused)
#   # → {"fallback": "fresh", "reason": "..."}     (surface gone / send failed)
#
# NOTE: the message is typed into a live claude REPL, which reads via bracketed
# paste. So the text and the submit are sent as two steps — `cmux send` for the
# literal text, then `cmux send-key Enter` to submit (see below). A trailing
# "\n" bundled into the `cmux send` does NOT submit; the REPL takes it as a
# literal newline in the input box. Callers still route multi-line follow-ups to
# the fresh-surface fallback (which uses a launch script); the single-line
# reuse path is the common case.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SURFACE_REF=""
SESSION_ID=""
PROMPT=""
KEEP_WORKSPACE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)        SURFACE_REF="$2";   shift 2 ;;
    --session)        SESSION_ID="$2";    shift 2 ;;
    --prompt)         PROMPT="$2";        shift 2 ;;
    --keep-workspace) KEEP_WORKSPACE=true; shift  ;;
    *)                shift ;;
  esac
done

fallback_fresh() {
  jq -n --arg reason "$1" '{fallback: "fresh", reason: $reason}'
  exit 0
}

[[ -z "$SURFACE_REF" ]] && fallback_fresh "no surface_ref provided"
[[ -z "$PROMPT"      ]] && { echo '{"error": "No --prompt provided"}'; exit 1; }

# Existence check: read-screen fails (non-zero) when the surface is gone. A live
# surface returns its current screen (non-empty for an idle claude REPL). Treat
# both a hard failure and an empty screen as "surface not usable" → fall back.
if ! SCREEN=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || [[ -z "$SCREEN" ]]; then
  fallback_fresh "surface $SURFACE_REF no longer exists or is not readable"
fi

CALL_DIR=$(mktemp -d /tmp/hotline-call-XXXXX)
echo "$SURFACE_REF" > "$CALL_DIR/surface_ref.txt"
echo "$KEEP_WORKSPACE" > "$CALL_DIR/keep_workspace.txt"
[[ -n "$SESSION_ID" ]] && {
  echo "$SESSION_ID" > "$CALL_DIR/session_id.txt"
  echo "$SESSION_ID" > "$CALL_DIR/session_id_preset.txt"
}

# Fresh per-call nonce so wait-for-response.sh distinguishes THIS turn's STATUS
# from the prior exchange's markers still in the surface's scrollback. Same
# generation ladder as cmux-call-async.sh.
CALL_ID=$(
  openssl rand -hex 8 2>/dev/null \
  || od -A n -N 8 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n' \
  || date +%s%N | sha256sum 2>/dev/null | cut -c1-16
)
echo "$CALL_ID" > "$CALL_DIR/call_id.txt"

# Follow-ups never re-wrap with /hotline-ringing (the ringing skill is already
# loaded in the remote session), so PROMPT is always a raw message — just prefix
# the nonce. The receiver echoes it back as `STATUS: <signal> call_id=<nonce>`.
MSG="[CALL_ID: $CALL_ID] $PROMPT"

# Type into the live REPL, then submit. The target is a claude TUI/Ink REPL that
# reads via bracketed paste — NOT a shell. Delivering text + a trailing "\n" in
# one `cmux send` makes the REPL treat the newline as a literal newline inside
# the input field, not a submit: the text lands but Enter never registers. So we
# send the text and the Enter as two distinct steps, with a short settle so the
# REPL finishes ingesting the paste before the submit key arrives (claude-plugins-5zhp).
# On failure the surface likely died between the check and now — clean up and
# fall back to a fresh surface.
if ! SEND_OUTPUT=$(cmux send --surface "$SURFACE_REF" "$MSG" 2>&1); then
  rm -rf "$CALL_DIR"
  fallback_fresh "cmux send into surface $SURFACE_REF failed: $SEND_OUTPUT"
fi
sleep 0.2
if ! SEND_OUTPUT=$(cmux send-key --surface "$SURFACE_REF" Enter 2>&1); then
  rm -rf "$CALL_DIR"
  fallback_fresh "cmux send-key Enter into surface $SURFACE_REF failed: $SEND_OUTPUT"
fi

jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
