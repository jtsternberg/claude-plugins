#!/usr/bin/env bash
# =============================================================================
# CMUX Paste: deliver a payload into a live claude REPL and PROVE it landed.
#
# The one delivery verb hotline uses over the cmux transport, for first contact
# and for follow-ups alike. Both callers hand it a file and a nonce; it resolves
# the surface's cmux address, pastes the file's bytes in a single
# `terminal.paste` RPC over the control socket, and then confirms the nonce
# reached the callee.
#
# WHY A SOCKET PASTE AND NOT `cmux send`:
#   • `cmux send` interprets \n, \r and \t in its text argument with no escape
#     hatch, so a payload had to be SPLIT to survive it (claude-plugins-nofy),
#     and it is sporadically lossy in ways that are not size-gated — a verified
#     3,045-byte payload lost 2,538 contiguous bytes with no error at all.
#   • `cmux rpc` would carry the paste, but takes its params as an argv string,
#     publishing whole work orders to `ps` (claude-plugins-86ka).
#   terminal.paste over the socket has neither problem: one request line, the
#   payload JSON-escaped in-process from a file. Measured 12/12 byte-exact to
#   16KB, and 18/18 multi-line trials landed as exactly ONE user turn.
#
# TWO LANDING SHAPES, both of which mean success:
#   idle REPL  → the payload is submitted and written as ONE user turn.
#   busy REPL  → it is QUEUED and written as a `queued_command` attachment, with
#                no user turn at all, and flushed at the next tool boundary.
#   A verifier that only counted user turns would read a landed queued paste as
#   lost and re-send it. Both shapes are accepted below.
#
# Usage:
#   cmux-paste.sh --surface <handle> --payload-file <path> --call-id <nonce>
#                 [--cwd <callee-cwd>] [--session <callee-session-id>]
#                 [--wait-box <seconds>]
#
#   # → {"delivered":true,"confirmed":"transcript"|"screen","workspace":"…","surface":"…"}
#   # → {"delivered":false,"reason":"…"}
#
# Always exits 0 with JSON: whether a failed delivery means "fall back to a
# fresh surface" or "fail the dial" is the caller's decision, not this script's.
#
# --wait-box polls until the REPL has drawn its input box, for a surface that was
# only just launched. Pasting into a shell that has not yet exec'd claude loses
# the payload silently, so first contact waits; a follow-up has already proven
# the box exists through its own gates and passes 0.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_SCRIPTS="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts"
# shellcheck source=../../../scripts/repl-state.sh
source "$HOTLINE_SCRIPTS/repl-state.sh"
CMUX_RPC="$HOTLINE_SCRIPTS/cmux-rpc.py"

SURFACE_REF=""
PAYLOAD_FILE=""
CALL_ID=""
CWD=""
SESSION_ID=""
WAIT_BOX=0
# Confirmation budget: 10 polls at 0.3s per tier. Generous enough for a
# transcript flush, short enough that a genuinely lost payload is reported in
# seconds rather than discovered a minute later by wait-for-response.sh.
CONFIRM_TRIES="${HOTLINE_PASTE_CONFIRM_TRIES:-10}"
CONFIRM_SLEEP="${HOTLINE_PASTE_CONFIRM_SLEEP:-0.3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)      SURFACE_REF="$2";  shift 2 ;;
    --payload-file) PAYLOAD_FILE="$2"; shift 2 ;;
    --call-id)      CALL_ID="$2";      shift 2 ;;
    --cwd)          CWD="$2";          shift 2 ;;
    --session)      SESSION_ID="$2";   shift 2 ;;
    --wait-box)     WAIT_BOX="$2";     shift 2 ;;
    *)              shift ;;
  esac
done

undelivered() { jq -nc --arg reason "$1" '{delivered: false, reason: $reason}'; exit 0; }

[[ -z "$SURFACE_REF"  ]] && undelivered "no surface handle given"
[[ -z "$CALL_ID"      ]] && undelivered "no --call-id nonce given; delivery could not be confirmed even if it landed"
[[ -z "$PAYLOAD_FILE" ]] && undelivered "no --payload-file given"
[[ -s "$PAYLOAD_FILE" ]] || undelivered "payload file is missing or empty: $PAYLOAD_FILE"
command -v python3 >/dev/null 2>&1 || undelivered "python3 not on PATH; the control-socket helper needs it"
[[ -f "$CMUX_RPC" ]] || undelivered "cmux-rpc.py not found at $CMUX_RPC"

# --- Where is this surface? --------------------------------------------------
ADDR=$(cmux_surface_address "$SURFACE_REF")
case $? in
  0) ;;
  3) undelivered "could not read the cmux tree to resolve surface $SURFACE_REF" ;;
  4) undelivered "surface $SURFACE_REF is not in the cmux tree, so its workspace and UUID are unknown" ;;
  *) undelivered "resolving surface $SURFACE_REF failed" ;;
esac
WS_ID="${ADDR%% *}"
SURF_ID="${ADDR##* }"

# --- Is the REPL drawn yet? -------------------------------------------------
if [[ "$WAIT_BOX" != "0" ]]; then
  BOX_DEADLINE=$(( $(date +%s) + WAIT_BOX ))
  BOX_READY=false
  while [[ $(date +%s) -le $BOX_DEADLINE ]]; do
    BOX_SCREEN=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || BOX_SCREEN=""
    if [[ -n "$BOX_SCREEN" ]] && repl_box_present "$BOX_SCREEN"; then
      BOX_READY=true
      break
    fi
    sleep 0.4
  done
  $BOX_READY || undelivered "surface $SURFACE_REF never drew a claude input box within ${WAIT_BOX}s; pasting into it would lose the payload"
fi

# --- One paste. -------------------------------------------------------------
# submit_key "return" submits an idle REPL and queues against a busy one; cmux
# upgrades it to ctrl+enter itself for multi-line Claude payloads, so there is no
# per-payload choice to make here.
RPC_ERR=$(mktemp)
if ! RPC_OUT=$(python3 "$CMUX_RPC" --method terminal.paste \
                 --workspace "$WS_ID" --surface "$SURF_ID" \
                 --payload-file "$PAYLOAD_FILE" --submit-key return 2>"$RPC_ERR"); then
  REASON=$(tr '\n\r\t' '   ' < "$RPC_ERR" | cut -c1-160)
  rm -f "$RPC_ERR"
  undelivered "terminal.paste into surface $SURF_ID failed: ${REASON:-no diagnostic}"
fi
rm -f "$RPC_ERR"

# --- Did the callee actually get it? ----------------------------------------
# ok:true is the socket's ack, not delivery proof. The no-trusting-exit-codes
# rule applies to an RPC exactly as it did to `cmux send`.
#
# PRIMARY — the callee's transcript. Byte-definitive, and immune both to the
# `[Pasted text +N lines]` collapse the screen shows for a large paste and to a
# viewport the user has scrolled away from.
#
# A plain grep for the nonce, deliberately, rather than a match on the specific
# JSONL shapes: the nonce is minted for THIS delivery and travels nowhere else,
# so any occurrence in the callee's transcript proves the paste arrived. Shape
# enumeration is how the old verifier read a landed queued paste as lost — and
# the live smoke test found a third shape (`queue-operation`) the design had not
# predicted, which a shape whitelist would also have missed.
#
# BOTH SPELLINGS OF THE CWD are tried. Claude Code derives the project directory
# from the cwd it actually resolved, so a callee under a symlinked path writes to
# the REALPATH encoding: a session in /tmp/x on macOS lands in
# ~/.claude/projects/-private-tmp-x, not -tmp-x. Deriving only from the path the
# caller happened to pass makes this tier miss every time for such a callee, and
# miss SILENTLY — the screen tier answers and nothing looks wrong (observed live:
# a delivery that landed perfectly reported confirmed:"screen").
TRANSCRIPTS=()
if [[ -n "$CWD" && -n "$SESSION_ID" ]]; then
  for _cwd in "$CWD" "$(realpath "$CWD" 2>/dev/null || true)"; do
    [[ -z "$_cwd" ]] && continue
    _p=$(bash "$HOTLINE_SCRIPTS/transcript-path.sh" --cwd "$_cwd" --session "$SESSION_ID" 2>/dev/null) || continue
    [[ -z "$_p" ]] && continue
    _seen=false
    for _e in ${TRANSCRIPTS[@]+"${TRANSCRIPTS[@]}"}; do [[ "$_e" == "$_p" ]] && _seen=true; done
    $_seen || TRANSCRIPTS+=("$_p")
  done
fi

confirmed_by_transcript() {
  local i t
  [[ ${#TRANSCRIPTS[@]} -eq 0 ]] && return 1
  for ((i = 0; i < CONFIRM_TRIES; i++)); do
    for t in "${TRANSCRIPTS[@]}"; do
      [[ -s "$t" ]] && grep -qF "$CALL_ID" "$t" 2>/dev/null && return 0
    done
    sleep "$CONFIRM_SLEEP"
  done
  return 1
}

# SECONDARY — the screen. For a callee whose cwd/session we were not told, or a
# transcript that has not flushed yet. Four acceptances, and all four must stay:
#   • the nonce itself — a short payload renders in the box verbatim.
#   • "[Pasted text"   — a large paste collapses to a placeholder, so the nonce
#                        is genuinely not on screen even though it landed.
#   • "Press up to edit queued" — the REPL was busy and queued it. That IS
#                        delivery; claude flushes it at the next tool boundary.
#   • "Jump to bottom" — the user has scrolled the surface up, so read-screen is
#                        returning a stale viewport and absence proves nothing.
#                        cmux exposes no primitive to snap a scrolled terminal
#                        back to its live tail. Re-sending here is a documented
#                        double-submit.
confirmed_by_screen() {
  local i scr
  for ((i = 0; i < CONFIRM_TRIES; i++)); do
    scr=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || scr=""
    if [[ -n "$scr" ]]; then
      printf '%s' "$scr" | grep -qF "$CALL_ID"                && return 0
      printf '%s' "$scr" | grep -qF '[Pasted text'            && return 0
      printf '%s' "$scr" | grep -qF 'Press up to edit queued' && return 0
      printf '%s' "$scr" | grep -qF 'Jump to bottom'          && return 0
    fi
    sleep "$CONFIRM_SLEEP"
  done
  return 1
}

CONFIRMED=""
if confirmed_by_transcript; then
  CONFIRMED="transcript"
elif confirmed_by_screen; then
  CONFIRMED="screen"
else
  undelivered "pasted into surface $SURFACE_REF but nonce $CALL_ID never appeared in the callee's transcript${TRANSCRIPTS[0]:+ (${TRANSCRIPTS[*]})} or on its screen; treating delivery as lost"
fi

jq -nc --arg c "$CONFIRMED" --arg w "$WS_ID" --arg s "$SURF_ID" \
  '{delivered: true, confirmed: $c, workspace: $w, surface: $s}'
