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
#                         [--cwd <path>] [--keep-workspace]
#   # → {"call_dir": "/tmp/hotline-call-XXXXX"}   (reused)
#   # → {"fallback": "fresh", "reason": "..."}     (surface gone / send failed)
#
# --cwd is the CALLEE session's working directory. It lets wait-for-response.sh
# derive the callee's JSONL transcript path and read the response from structured
# data instead of scraping the screen (its preferred path). Omitting it still
# works — wait-for-response falls back to screen-scraping.
#
# NOTE: the message is typed into a live claude REPL, which reads via bracketed
# paste. So it goes in three steps — first a raw Ctrl-C byte ($'\003') via
# `cmux send` to clear any leftover input in the prompt box, then `cmux send`
# for the literal text, then `cmux send-key Enter` to submit (see below). A
# trailing "\n" bundled into the `cmux send` does NOT submit; the REPL takes it
# as a literal newline in the input box. (`send-key ctrl+c` does NOT reach an
# in-pane claude REPL — only the raw byte via the text path clears it.) Callers
# still route multi-line follow-ups to the fresh-surface fallback (which uses a
# launch script); the single-line reuse path is the common case.
#
# NOTE: `cmux send` interprets the two-character sequences \n, \r and \t in its
# text argument, and offers no way to escape a backslash — so the payload is
# SPLIT so that no single argument ever contains one (claude-plugins-nofy).
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SURFACE_REF=""
SESSION_ID=""
PROMPT=""
CWD=""
KEEP_WORKSPACE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)        SURFACE_REF="$2";   shift 2 ;;
    --session)        SESSION_ID="$2";    shift 2 ;;
    --prompt)         PROMPT="$2";        shift 2 ;;
    --cwd)            CWD="$2";           shift 2 ;;
    --keep-workspace) KEEP_WORKSPACE=true; shift  ;;
    *)                shift ;;
  esac
done

fallback_fresh() {
  jq -n --arg reason "$1" '{fallback: "fresh", reason: $reason}'
  exit 0
}

# --- Delivering a payload through `cmux send` without escape mangling --------
# `cmux send` documents "Escape sequences: \n and \r send Enter, \t sends Tab",
# and there is NO backslash escape to opt out with. Verified live on cmux
# 0.64.20 against a `cat > file` probe: `\\` arrives as TWO backslashes and
# `\\n` arrives as one backslash + Enter, so doubling backslashes makes the
# corruption worse rather than fixing it. What DOES work is denying the scanner
# the two-character sequence in the first place: split the payload just after
# each backslash that precedes n/r/t and send the pieces back to back. Each
# `send` is its own bracketed paste appending at the cursor, so the box
# accumulates the exact bytes (verified: send 'a\' then send 'nb' lands `a\nb`).
#
# `cmux set-buffer` + `paste-buffer` also delivers verbatim, but its --surface
# resolution differs from `send`'s (a bare `surface:N` ref that `send` accepts
# fails there with "Surface is not a terminal" unless --window is also passed),
# so it would change targeting semantics for every caller. Splitting keeps the
# proven targeting. (claude-plugins-nofy)
CMUX_SEND_CHUNKS=()
split_for_cmux_send() {
  local rest="$1" head
  CMUX_SEND_CHUNKS=()
  while [[ "$rest" == *\\[nrt]* ]]; do
    # %% strips the longest matching suffix, i.e. leaves the prefix up to the
    # FIRST \n/\r/\t. The backslash goes out at the end of this chunk; the n/r/t
    # starts the next one.
    head="${rest%%\\[nrt]*}"
    CMUX_SEND_CHUNKS+=("${head}\\")
    rest="${rest:${#head}+1}"
  done
  [[ -n "$rest" ]] && CMUX_SEND_CHUNKS+=("$rest")
  return 0
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
# Persist the callee's cwd so wait-for-response.sh can derive the transcript path
# (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl) and read the response
# from structured JSONL rather than the rendered screen.
[[ -n "$CWD" ]] && echo "$CWD" > "$CALL_DIR/cwd.txt"

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

# Clear the REPL input box before typing. The surface holds an idle claude REPL,
# but its prompt box may still contain leftover input (the human typed into it
# while it sat idle, or a prior send never submitted). If so, our text gets
# prepended to that leftover and the whole line is garbage — the follow-up
# silently never runs. `send-key ctrl+c` does NOT reach an in-pane claude REPL
# (verified against Claude Code v2.1.216); the raw Ctrl-C byte via the TEXT path
# does, and reliably clears the box regardless of cursor position. Best-effort:
# a failure here isn't fatal (the box is usually empty), so don't fall back on it.
cmux send --surface "$SURFACE_REF" $'\003' >/dev/null 2>&1 || true
sleep 0.2

# Type into the live REPL, then submit. The target is a claude TUI/Ink REPL that
# reads via bracketed paste — NOT a shell. Delivering text + a trailing "\n" in
# one `cmux send` makes the REPL treat the newline as a literal newline inside
# the input field, not a submit: the text lands but Enter never registers. So we
# send the text and the Enter as two distinct steps, with a short settle so the
# REPL finishes ingesting the paste before the submit key arrives (claude-plugins-5zhp).
#
# The text goes out in one `send` per chunk (usually exactly one — the split only
# kicks in for payloads containing a literal \n / \r / \t). `--` guards against a
# payload that starts with a dash. On failure the surface likely died between the
# check and now — clean up and fall back to a fresh surface.
split_for_cmux_send "$MSG"
for CHUNK in "${CMUX_SEND_CHUNKS[@]}"; do
  if ! SEND_OUTPUT=$(cmux send --surface "$SURFACE_REF" -- "$CHUNK" 2>&1); then
    rm -rf "$CALL_DIR"
    fallback_fresh "cmux send into surface $SURFACE_REF failed: $SEND_OUTPUT"
  fi
  # Let the REPL ingest each paste before the next one appends to it. Skipped
  # entirely in the single-chunk common case so the fast path stays fast.
  if [[ ${#CMUX_SEND_CHUNKS[@]} -gt 1 ]]; then sleep 0.1; fi
done
sleep 0.2
if ! SEND_OUTPUT=$(cmux send-key --surface "$SURFACE_REF" Enter 2>&1); then
  rm -rf "$CALL_DIR"
  fallback_fresh "cmux send-key Enter into surface $SURFACE_REF failed: $SEND_OUTPUT"
fi

jq -n --arg dir "$CALL_DIR" '{call_dir: $dir}'
