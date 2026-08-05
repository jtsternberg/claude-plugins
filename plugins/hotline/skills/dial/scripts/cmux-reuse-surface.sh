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
# paste. So `cmux send` delivers the literal text and `cmux send-key Enter`
# submits it as a separate step — a trailing "\n" bundled into the `cmux send`
# does NOT submit; the REPL takes it as a literal newline in the input box.
# Callers still route multi-line follow-ups to the fresh-surface fallback (which
# uses a launch script); the single-line reuse path is the common case.
#
# Two transport hazards are handled below, both verified live (claude 2.1.221 /
# cmux 0.64.20):
#
#   • `cmux send` interprets the two-character sequences \n, \r and \t in its
#     text argument, and offers no way to escape a backslash — so the payload is
#     SPLIT so that no single argument ever contains one (claude-plugins-nofy).
#
#   • The input-box clear is a raw Ctrl-C byte, which is a real interrupt. It is
#     now sent only when the box demonstrably holds unsent text AND the REPL
#     shows no sign of an active turn (claude-plugins-06ws).
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
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

# --- Reading the REPL's state off its rendered screen -------------------------
# The claude REPL draws its input box as a `❯`-prefixed line between two
# horizontal rules at the bottom of the screen. The transcript above it echoes
# prior user turns with the SAME glyph, so more than one candidate line is
# usually on screen. Two things disambiguate, in order of reliability:
#   1. The live box pads its glyph with a NO-BREAK SPACE (U+00A0); the transcript
#      echoes use a plain space. Verified on claude 2.1.221.
#   2. Failing that, the box is the LAST such line — it's drawn at the bottom.
# Byte escapes rather than \u so this still works under bash 3.2 (macOS system).
BOX_GLYPH=$'\xe2\x9d\xaf'   # ❯
BOX_NBSP=$'\xc2\xa0'        # the box's padding after the glyph

# Echoes whatever text is sitting in the REPL's input box ("" when it's empty).
input_box_content() {
  local screen="$1" line
  line=$(printf '%s\n' "$screen" | grep "^${BOX_GLYPH}${BOX_NBSP}" | tail -1) || true
  if [[ -z "$line" ]]; then
    line=$(printf '%s\n' "$screen" | grep "^${BOX_GLYPH}" | tail -1) || true
  fi
  [[ -z "$line" ]] && return 0
  line="${line#"$BOX_GLYPH"}"
  # Strip the padding (NBSP and/or ordinary blanks) between glyph and content.
  while :; do
    case "$line" in
      "$BOX_NBSP"*) line="${line#"$BOX_NBSP"}" ;;
      " "*)         line="${line# }" ;;
      $'\t'*)       line="${line#$'\t'}" ;;
      *)            break ;;
    esac
  done
  # An untouched REPL renders a greyed placeholder hint INSIDE an empty box.
  # read-screen strips the colour that would distinguish it, so match its shape.
  case "$line" in
    'Try "'*) return 0 ;;
  esac
  printf '%s' "$line" | sed 's/[[:space:]]*$//'
}

# True when the screen shows a turn in flight. Two independent markers, because
# neither is dependable alone: "esc to interrupt" is absent in some versions
# (including 2.1.221), and the spinner's wording changes between releases — but
# a RUNNING spinner always carries a live elapsed-time parenthetical, e.g.
# "✶ Dilly-dallying… (5s · ↓ 124 tokens · …)", whereas the finished one does not
# ("✻ Baked for 12s"). Callers add a screen-stability check on top.
repl_looks_busy() {
  local screen="$1"
  grep -qi 'esc to interrupt' <<<"$screen" && return 0
  grep -qE '\([0-9]+s[ )·]' <<<"$screen" && return 0
  return 1
}

# The post-interrupt "what now?" state. It is not busy, but it is not accepting
# a follow-up on our terms either — anything we type becomes an answer to that
# question rather than a new turn (claude-plugins-06ws acceptance criteria).
repl_is_interrupted() {
  grep -qiE 'What should Claude do instead|Request interrupted by user' <<<"$1"
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

# --- Decide, BEFORE typing anything, whether this REPL will accept a follow-up
# and whether its input box needs clearing first (claude-plugins-06ws).
#
# The old unconditional Ctrl-C was harmful three ways, all verified: mid-tool-call
# it destroys the callee's in-flight tool call; during the pre-tool thinking phase
# it writes no interrupt record but restores the just-submitted prompt into the
# box, so the follow-up welds onto its tail and resubmits as one corrupted turn
# (2/2); and it sometimes silently fails to fire at all. Meanwhile text+Enter into
# a busy REPL is SAFE — the message is enqueued and delivered at the next tool
# boundary or flushed after the turn ends. So the interrupt is what we withhold,
# not the message.
#
# The clear is not simply deleted: leftover text in the box would prepend to our
# message, and falling back to a fresh surface every time the box is dirty would
# make that surface permanently unreusable (the leftover never goes away) —
# exactly the surface-stacking this script exists to prevent.
if repl_is_interrupted "$SCREEN"; then
  fallback_fresh "surface $SURFACE_REF is in the post-interrupt 'what should Claude do instead?' state; a follow-up typed here would answer that prompt instead of starting a turn"
fi

PARKED=$(input_box_content "$SCREEN")
NEEDS_CLEAR=false
if [[ -n "$PARKED" ]]; then
  # Something is parked in the box. Clearing it costs a real interrupt, so only
  # do it against a REPL that is provably quiet: no in-flight markers, AND a
  # screen that hasn't changed over a short window (a live spinner or streaming
  # output moves even when the marker wording is one we don't know).
  if repl_looks_busy "$SCREEN"; then
    fallback_fresh "surface $SURFACE_REF has unsent text in its input box while a turn is in flight; clearing it would interrupt that turn and sending would weld onto the leftover"
  fi
  sleep 0.6
  if ! SCREEN2=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || [[ -z "$SCREEN2" ]]; then
    fallback_fresh "surface $SURFACE_REF became unreadable while checking whether its REPL was idle"
  fi
  if [[ "$SCREEN2" != "$SCREEN" ]]; then
    fallback_fresh "surface $SURFACE_REF has unsent text in its input box and its screen is still changing (REPL busy); refusing to interrupt"
  fi
  NEEDS_CLEAR=true
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

# Follow-ups never re-wrap with /hotline:hotline-ringing (the ringing skill is already
# loaded in the remote session), so PROMPT is always a raw message — just prefix
# the nonce. The receiver echoes it back as `STATUS: <signal> call_id=<nonce>`.
MSG="[CALL_ID: $CALL_ID] $PROMPT"

# Clear the parked text out of the input box, then PROVE it went — the Ctrl-C is
# known to silently no-op sometimes (observed while the callee's stop hooks ran).
# If the box is still dirty we must not type: our message would prepend to the
# leftover and the whole line would run as garbage. `send-key ctrl+c` does NOT
# reach an in-pane claude REPL (verified against Claude Code v2.1.216); the raw
# Ctrl-C byte via the TEXT path does, regardless of cursor position.
if $NEEDS_CLEAR; then
  cmux send --surface "$SURFACE_REF" $'\003' >/dev/null 2>&1 || true
  sleep 0.4
  if ! SCREEN3=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) \
     || [[ -n "$(input_box_content "$SCREEN3")" ]]; then
    rm -rf "$CALL_DIR"
    fallback_fresh "could not clear unsent text out of surface $SURFACE_REF's input box; refusing to type on top of it"
  fi
fi

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
