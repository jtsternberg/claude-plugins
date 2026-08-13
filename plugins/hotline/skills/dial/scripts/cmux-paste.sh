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
#                 [--wait-box <seconds>] [--workspace <uuid>] [--baseline <path>]
#
#   # → {"delivered":true,"sent":true,"confirmed":"transcript"|"screen","workspace":"…","surface":"…"}
#   # → {"delivered":false,"sent":false,"reason":"…"}   nothing left this machine
#   # → {"delivered":false,"sent":true,"reason":"…"}    the socket took it; landing unproven
#
# Always exits 0 with JSON: whether a failed delivery means "fall back to a
# fresh surface" or "fail the dial" is the caller's decision, not this script's.
#
# `sent` is what makes that decision safe. delivered:false with sent:false means
# the callee received nothing, so delivering somewhere else is fine. delivered:false
# with sent:TRUE means the payload may already be in the callee's input queue and
# only the confirmation missed — re-delivering it runs the work order twice.
#
# --wait-box polls until the REPL has drawn its input box. This is not politeness
# about a slow boot: a payload delivered to a surface that has not exec'd claude
# does not vanish, it goes to whatever IS there, and a shell with
# submit_key:"return" RUNS it. First contact waits; a follow-up whose caller has
# already proven the box on its own screen read passes 0.
#
# --workspace lets a caller that already walked the cmux tree hand over the
# workspace UUID instead of making this script walk it again.
#
# --baseline names a file holding the pre-paste screen. Confirmation needs to know
# which screen markers were ALREADY there, so a previous exchange's chrome cannot
# confirm this delivery (see the screen tier below). Without it, one read is taken
# here.
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
WORKSPACE_ID=""
BASELINE_FILE=""
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
    --workspace)    WORKSPACE_ID="$2"; shift 2 ;;
    --baseline)     BASELINE_FILE="$2"; shift 2 ;;
    *)              shift ;;
  esac
done

# undelivered <reason> [sent]
#
# `sent` is the whole safety distinction, and it is not cosmetic. A failure BEFORE
# the paste went out (no input box, unresolvable surface, an RPC the socket
# refused) means the callee received nothing, so re-delivering somewhere else is
# safe. A failure AFTER the socket accepted it means the payload may well have
# landed and only the confirmation missed — re-delivering then runs the work order
# TWICE. Callers branch on this, so it is reported rather than inferred.
PASTE_SENT=false
undelivered() {
  jq -nc --arg reason "$1" --argjson sent "${2:-$PASTE_SENT}" \
    '{delivered: false, sent: $sent, reason: $reason}'
  exit 0
}

[[ -z "$SURFACE_REF"  ]] && undelivered "no surface handle given"
[[ -z "$CALL_ID"      ]] && undelivered "no --call-id nonce given; delivery could not be confirmed even if it landed"
[[ -z "$PAYLOAD_FILE" ]] && undelivered "no --payload-file given"
[[ -s "$PAYLOAD_FILE" ]] || undelivered "payload file is missing or empty: $PAYLOAD_FILE"
command -v python3 >/dev/null 2>&1 || undelivered "python3 not on PATH; the control-socket helper needs it"
[[ -f "$CMUX_RPC" ]] || undelivered "cmux-rpc.py not found at $CMUX_RPC"

# --- Where is this surface? --------------------------------------------------
# The caller may already have walked the tree to find this surface (dial.sh does,
# for a workspace-addressed call). Taking its answer skips a second read of the
# same JSON — and, more importantly, means there is only one place that walk lives.
if [[ -n "$WORKSPACE_ID" && "$SURFACE_REF" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  WS_ID="$WORKSPACE_ID"
  SURF_ID="$SURFACE_REF"
else
  ADDR=$(cmux_surface_address "$SURFACE_REF")
  case $? in
    0) ;;
    3) undelivered "could not read the cmux tree to resolve surface $SURFACE_REF" ;;
    4) undelivered "surface $SURFACE_REF is not in the cmux tree, so its workspace and UUID are unknown" ;;
    *) undelivered "resolving surface $SURFACE_REF failed" ;;
  esac
  WS_ID="${ADDR%% *}"
  SURF_ID="${ADDR##* }"
fi

# --- Is the REPL drawn yet, and what did the screen look like before? --------
# BASELINE is the screen as it stood BEFORE this paste. Confirmation needs it:
# three of the four screen-side landing markers are generic strings that a
# PREVIOUS exchange leaves sitting in the viewport of a reused surface, so
# accepting one that was already there confirms a paste that never arrived.
#
# --baseline lets a caller pass a snapshot it already took (cmux-reuse-surface.sh
# reads the screen several times for its gates); otherwise one read is taken here.
BASELINE=""
if [[ -n "$BASELINE_FILE" && -f "$BASELINE_FILE" ]]; then
  BASELINE=$(cat "$BASELINE_FILE")
fi

if [[ "$WAIT_BOX" != "0" ]]; then
  BOX_DEADLINE=$(( $(date +%s) + WAIT_BOX ))
  BOX_READY=false
  while [[ $(date +%s) -le $BOX_DEADLINE ]]; do
    BOX_SCREEN=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || BOX_SCREEN=""
    if [[ -n "$BOX_SCREEN" ]] && repl_box_present "$BOX_SCREEN"; then
      BOX_READY=true
      # The screen that proved the box is the freshest possible baseline.
      BASELINE="$BOX_SCREEN"
      break
    fi
    sleep 0.4
  done
  $BOX_READY || undelivered "surface $SURFACE_REF never drew a claude input box (a ❯ padded with U+00A0) within ${WAIT_BOX}s; delivering now would paste the payload into whatever IS there — a shell would run it"
fi

if [[ -z "$BASELINE" ]]; then
  BASELINE=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || BASELINE=""
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
  # The socket refused it, so nothing reached the callee: safe to try elsewhere.
  undelivered "terminal.paste into surface $SURF_ID failed: ${REASON:-no diagnostic}" false
fi
rm -f "$RPC_ERR"
# From here on the payload may be in the callee's input queue whatever we observe.
PASTE_SENT=true

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
#
# THE LAST THREE NEED A RECENCY BASELINE. They are generic chrome, and the whole
# point of this path is that the surface is REUSED — so a previous exchange's
# `[Pasted text +40 lines]`, or a "Press up to edit queued messages" from a
# follow-up two turns ago, is very often still in the viewport. Matched blind,
# each of them confirms a paste that never arrived, which is worse than no check
# at all: the caller then blocks on wait-for-response until it times out.
#
# So a marker only counts if it is ABSENT from the pre-paste baseline. The nonce
# needs no such treatment — it is minted for this delivery and cannot be stale.
SCREEN_MARKERS=('[Pasted text' 'Press up to edit queued' 'Jump to bottom')
FRESH_MARKERS=()
for _m in "${SCREEN_MARKERS[@]}"; do
  printf '%s' "$BASELINE" | grep -qF "$_m" || FRESH_MARKERS+=("$_m")
done

confirmed_by_screen() {
  local i scr m
  for ((i = 0; i < CONFIRM_TRIES; i++)); do
    scr=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || scr=""
    if [[ -n "$scr" ]]; then
      printf '%s' "$scr" | grep -qF "$CALL_ID" && return 0
      for m in ${FRESH_MARKERS[@]+"${FRESH_MARKERS[@]}"}; do
        printf '%s' "$scr" | grep -qF "$m" && return 0
      done
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
  '{delivered: true, sent: true, confirmed: $c, workspace: $w, surface: $s}'
