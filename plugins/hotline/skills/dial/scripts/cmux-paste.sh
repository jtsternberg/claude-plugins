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
# Settle between a paste and the Enter key event that submits it. The key event
# travels a different path than the paste, so sent in the same breath it can reach
# the REPL before the bytes it is meant to submit have been ingested, and the Enter
# is swallowed (claude-plugins-5zhp). 0.2s is the measured margin.
SUBMIT_SETTLE="${HOTLINE_SUBMIT_SETTLE:-0.2}"

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

# EVERY READ IN THIS SCRIPT IS SCROLL-IMMUNE, via read_live below. A plain
# `cmux read-screen` returns whatever the surface is CURRENTLY SHOWING, so a user
# who has scrolled the pane up freezes the capture — and this gate would then wait
# out its whole budget for a box that has been drawn the entire time, refusing a
# delivery that was perfectly safe. `--scrollback --lines N` returns the live tail
# regardless of scroll position (repl-state.sh; verified on cmux 0.64.22).
#
# The result is TAILED to the live screen rows before any state judgement reads it.
# Box presence, busy markers and box content are all bottom-of-screen facts, and a
# 400-line read still holds `❯` echoes and elapsed-time parentheticals from turns
# that ended long ago — matching those would report a box (or a busy REPL) that is
# not there now. The scrollback width only exists so the read cannot be scrolled
# out from under us, not to widen what these predicates see.
#
# HOW MANY ROWS "THE LIVE SCREEN" IS, is measured where it can be — but NOT during
# the box wait below. cmux_screen_rows counts the rows a bare read returns
# (repl-state.sh), and that count is only the truth about a pane whose screen is
# already drawn. During --wait-box the REPL is still coming up: a measurement taken
# then reports the two or three rows a shell has printed, and every window derived
# from it would stay that narrow for the rest of the call — the box gate would never
# see the box it is waiting for (hard timeout on a healthy boot) and the baseline
# would be nearly empty, which makes every generic screen marker look FRESH and
# confirms deliveries that never landed. So the loop runs on the 60-row constant,
# exactly as before, and the measurement happens once the box is proven.
PANE_ROWS=""
SCREEN_TAIL=$(repl_screen_tail_lines "")

measure_pane() {
  PANE_ROWS=$(cmux_screen_rows "paste to surface $SURFACE_REF" --surface "$SURFACE_REF" || true)
  SCREEN_TAIL=$(repl_screen_tail_lines "$PANE_ROWS")
}

read_raw() {
  local raw
  raw=$(cmux_read_live "paste to surface $SURFACE_REF" --surface "$SURFACE_REF") || return 1
  [[ -z "$raw" ]] && return 1
  printf '%s' "$raw"
}

read_live() {
  local raw
  raw=$(read_raw) || return 1
  repl_screen_tail "$raw" "$SCREEN_TAIL"
}

BOX_RAW=""
if [[ "$WAIT_BOX" != "0" ]]; then
  BOX_DEADLINE=$(( $(date +%s) + WAIT_BOX ))
  BOX_READY=false
  while [[ $(date +%s) -le $BOX_DEADLINE ]]; do
    BOX_RAW=$(read_raw) || BOX_RAW=""
    # The box gate reads only the BOTTOM of the capture, not the whole pane-height
    # tail the confirmation tiers below use. repl_box_present matches anywhere in its
    # window, so on a pane shorter than that tail the window reaches into history —
    # and a dead REPL's final frame (its box render, a shell prompt underneath) then
    # proves a REPL that has exited. This gate is the one thing standing between a
    # work order and a shell that would RUN it, so it gets the tight window; the
    # nonce and busy checks keep the wider one, where a miss only costs a refusal.
    #
    # THE CONSTANT, not a measured window: see measure_pane above. Here, too small
    # is the harmful direction — this loop is waiting for a screen that does not
    # exist yet.
    BOX_WINDOW=""
    [[ -n "$BOX_RAW" ]] && BOX_WINDOW=$(repl_screen_tail "$BOX_RAW" "$HOTLINE_BOX_TAIL_LINES")
    if [[ -n "$BOX_WINDOW" ]] && repl_box_present "$BOX_WINDOW"; then
      BOX_READY=true
      break
    fi
    # THE STARTUP TRUST DIALOG, which is why this loop can otherwise wait out its
    # whole budget and then report a REPL that "never drew a claude input box": a
    # callee launched into a directory Claude Code has not trusted parks on the trust
    # prompt, which draws no box and never will. wait-for-session.sh makes this same
    # refusal for every other cmux dial, but a CONFERENCE never reaches it — dial.sh
    # step 5b goes through cmux-call.sh straight to this script — so without this the
    # one path that first surfaced claude-plugins-6y0s stayed uncovered.
    #
    # CHECKED ONLY WHEN NO BOX IS DRAWN, unlike the boot wait, which checks the dialog
    # first. Here a live box is proof the REPL is past this gate, so a dialog somebody
    # answered in this surface earlier — still sitting in the same tail window — can
    # never refuse a delivery that was safe. Nothing has been pasted at this point,
    # which is what lets the refusal promise that and report sent:false.
    if [[ -n "$BOX_WINDOW" ]] && repl_trust_dialog_present "$BOX_WINDOW"; then
      undelivered "$(repl_trust_dialog_refusal --surface "$SURFACE_REF" "$CWD")" false
    fi
    sleep 0.4
  done
  $BOX_READY || undelivered "surface $SURFACE_REF never drew a claude input box (a ❯ padded with U+00A0) within ${WAIT_BOX}s; delivering now would paste the payload into whatever IS there — a shell would run it. The read is scroll-immune, so a scrolled pane is not the cause."
fi

# The box is proven (or the caller proved it and passed --wait-box 0), so the pane is
# showing what the tiers below will judge. The BASELINE is taken at the pane's
# measured width — preferably out of the capture that already proved the box, which
# costs no extra cmux call — because the freshness test compares this screen against
# the post-paste one, and a baseline NARROWER than the confirmation reads would let a
# marker it simply could not see count as fresh and confirm a delivery that never
# arrived.
#
# Only measured when we are actually taking a baseline: a caller that passes
# --baseline has taken one at its own reading of this same pane
# (cmux-reuse-surface.sh does), and measuring here would spend a cmux call to size
# nothing.
if [[ -z "$BASELINE" ]]; then
  measure_pane
  if [[ -n "$BOX_RAW" ]]; then
    BASELINE=$(repl_screen_tail "$BOX_RAW" "$SCREEN_TAIL")
  else
    BASELINE=$(read_live) || BASELINE=""
  fi
fi

# --- Deliver the paste(s). ---------------------------------------------------
# ONE paste for an ordinary payload; TWO for a first-contact slash command whose
# body would otherwise sink the whole invocation.
#
# One paste, submit_key "return": submits an idle REPL and queues against a busy
# one; cmux upgrades it to ctrl+enter itself for multi-line Claude payloads, so
# there is no per-payload choice to make in that case.
#
# TWO pastes — the first-contact slash case (claude-plugins-pmgb). CC's TUI
# collapses any single paste over ~800 chars or 3 lines into a
# `[Pasted text +N lines]` placeholder. When that placeholder is the START of the
# input the leading `/` is gone, the slash command never parses, and the callee
# gets the work order as PLAIN TEXT with no ringing protocol — no STATUS, no
# call_id — so the caller's wait-for-response misreads the silence as a reassigned
# callee. Delivering the invocation line in its own small paste keeps the buffer
# starting with `/` so the command parses; the body rides a second paste whose
# placeholder CC expands back inside the command args on submit (probe-verified
# live on CC 2.1.226: slash parsed AND every body marker present in
# <command-args>, both when the body was glued to the invocation and when it sat
# on its own line below it). The split fires only for a slash-command first line
# that HAS a body beneath it; single-line invocations and all follow-ups take the
# one-paste path unchanged.
#
# The two-paste sequence does NOT let either paste submit (submit_key none); a
# real Enter KEY EVENT after both land is what submits, because it arrives outside
# the bracketed paste (phase-2 + the pmgb probe both confirmed this submits the
# whole box as one turn where an in-paste submit key would not).
paste_one() { # <payload-file> <submit-key>  — undelivered() exits on socket refusal
  local _file="$1" _submit="$2" _err _out _reason
  _err=$(mktemp)
  if ! _out=$(python3 "$CMUX_RPC" --method terminal.paste \
                --workspace "$WS_ID" --surface "$SURF_ID" \
                --payload-file "$_file" --submit-key "$_submit" 2>"$_err"); then
    _reason=$(tr '\n\r\t' '   ' < "$_err" | cut -c1-160)
    rm -f "$_err"
    # PASTE_SENT is false before the first paste (nothing reached the callee, so a
    # retry elsewhere is safe) and true once any paste has gone out (a retry could
    # double-run). undelivered reads it so the reason reports the truth either way.
    undelivered "terminal.paste into surface $SURF_ID failed: ${_reason:-no diagnostic}" "$PASTE_SENT"
  fi
  rm -f "$_err"
}

# Whether to split turns on the SAME predicate the herdr transport splits on, and on
# the same judgement that decides inline-vs-leading-line nonce placement — they are
# one design invariant (a slash command gets an inline nonce AND a split delivery),
# so every reader takes it from repl-state.sh rather than restating it.
SPLIT_PASTE=false
hotline_payload_needs_split_delivery "$PAYLOAD_FILE" && SPLIT_PASTE=true

if $SPLIT_PASTE; then
  HEAD_FILE=$(mktemp); BODY_FILE=$(mktemp)
  # paste_one calls undelivered (which exits) on a socket refusal, before the rm
  # below runs — so a trap owns the cleanup, or the temp files leak on that path.
  trap 'rm -f "$HEAD_FILE" "$BODY_FILE"' EXIT
  # HEAD keeps its trailing newline so the body lands on its own line below the
  # invocation; the two halves together reconstruct the payload byte-for-byte.
  sed -n '1p' "$PAYLOAD_FILE" > "$HEAD_FILE"
  tail -n +2  "$PAYLOAD_FILE" > "$BODY_FILE"
  paste_one "$HEAD_FILE" none
  # The invocation line is in the callee's box now; a later failure must not claim
  # nothing was sent.
  PASTE_SENT=true
  paste_one "$BODY_FILE" none
  rm -f "$HEAD_FILE" "$BODY_FILE"; trap - EXIT
  # Submit with a real key event, outside any bracketed paste — after the settle
  # (see SUBMIT_SETTLE).
  sleep "$SUBMIT_SETTLE"
  if ! cmux send-key --surface "$SURFACE_REF" Enter >/dev/null 2>&1; then
    undelivered "pasted both halves into surface $SURF_ID but the submit Enter keystroke failed" true
  fi
else
  paste_one "$PAYLOAD_FILE" return
  # From here on the payload may be in the callee's input queue whatever we observe.
  PASTE_SENT=true
fi

# THE PANE IS RE-MEASURED NOW, because the paste is what changed its height. A
# screen that was not already full GROWS when the turn echoes into it, so the
# pre-paste height is a lower bound afterwards — and a window sized to it drops the
# NEWEST rows, which is precisely where the echo the tiers below look for sits. On a
# near-empty pane that turns a landed delivery into delivered:false/sent:true.
# Re-measuring also keeps this window reaching zero rows into history, the same as
# the baseline's, so "not on the pre-paste screen" keeps meaning fresh.
cmux_screen_rows_forget
measure_pane

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
#                        is genuinely not on screen even though it landed. Counts
#                        only OUTSIDE the input box (see below): in the box, the
#                        placeholder means the payload arrived and never submitted.
#   • "Press up to edit queued" — the REPL was busy and queued it. That IS
#                        delivery; claude flushes it at the next tool boundary. The
#                        one marker that also counts ON the box line, because claude
#                        draws it there as a placeholder (see QUEUED_HINT below).
#   • "Jump to bottom" — a BACKSTOP, not the main defence. Every read here is
#                        scroll-immune (read_live), so a scrolled pane returns the
#                        live tail and this marker should not appear at all. It is
#                        kept because absence of the nonce on a capture we somehow
#                        cannot trust proves nothing, and re-sending on that
#                        reading is a documented double-submit.
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
#
# AND EVERY ACCEPTANCE IS SCOPED TO THE SCREEN OUTSIDE THE LIVE INPUT BOX. A
# marker on the box line proves the payload ARRIVED; it says nothing about whether
# it SUBMITTED, and the two are exactly what this tier has to tell apart. `❯ [Pasted
# text #2 +6 lines]` sitting in the box IS the unsubmitted state — the same state
# payload_is_parked classifies below — so counting it here confirms a delivery that
# is still waiting for its Enter, and the parked-retry path never runs
# (claude-plugins-y4rl). A marker rendered elsewhere — a scrollback echo of a
# submitted turn, the scrolled-viewport banner — carries information about
# submission; box CONTENT does not.
#
# ONE MARKER IS EXEMPT FROM THE BOX EXCLUSION, and only this one: the
# queued-messages hint, which Claude Code renders INSIDE the box as a placeholder.
# Excluding the box line therefore deletes a queued delivery's strongest proof. It is
# safe to accept there because a placeholder proves the input's VALUE is empty — the
# TUI draws one only when `value.length === 0` — so our payload cannot be parked in a
# box that is showing it, and the hint's presence proves the queue is non-empty. The
# nonce and `[Pasted text` get no such exemption: both render as real box CONTENT,
# where they mean "arrived, not submitted" (claude-plugins-y4rl).
QUEUED_HINT='Press up to edit queued'
SCREEN_MARKERS=('[Pasted text' "$QUEUED_HINT" 'Jump to bottom')
FRESH_MARKERS=()
for _m in "${SCREEN_MARKERS[@]}"; do
  printf '%s' "$BASELINE" | grep -qF "$_m" || FRESH_MARKERS+=("$_m")
done
# What the input box held BEFORE this paste. The parked classifier compares against
# it: box content that was already there cannot be the payload we just sent, and an
# Enter fired on it would submit someone else's text.
BASELINE_BOX=$(input_box_content "$BASELINE")

# screen_outside_box <screen> — the screen with the live input box's own line taken
# out, so nothing sitting IN the box can confirm submission.
#
# input_box_content (repl-state.sh) already owns the judgement of which line the box
# is; this drops every `❯`-prefixed line carrying that content rather than trying to
# re-derive the one line number, because a scrollback echo of the same bytes cannot
# distinguish itself from the live box anyway. Dropping one line too many can only
# withhold a confirmation, never fabricate one — the safe direction.
screen_outside_box() {
  local scr="$1" box
  box=$(input_box_content "$scr")
  if [[ -z "$box" ]]; then
    printf '%s' "$scr"
    return 0
  fi
  printf '%s\n' "$scr" | awk -v g="$REPL_BOX_GLYPH" -v b="$box" '
    index($0, g) == 1 && index($0, b) > 0 { next }
    { print }'
}

confirmed_by_screen() {
  local i scr outside m
  for ((i = 0; i < CONFIRM_TRIES; i++)); do
    scr=$(read_live) || scr=""
    if [[ -n "$scr" ]]; then
      outside=$(screen_outside_box "$scr")
      printf '%s' "$outside" | grep -qF "$CALL_ID" && return 0
      for m in ${FRESH_MARKERS[@]+"${FRESH_MARKERS[@]}"}; do
        printf '%s' "$outside" | grep -qF "$m" && return 0
        # The queued hint also counts as the box's own content — see QUEUED_HINT
        # above. Still freshness-gated: a hint left over from a previous exchange
        # never reaches this loop, because FRESH_MARKERS excluded it.
        if [[ "$m" == "$QUEUED_HINT" ]] \
           && printf '%s' "$(input_box_content "$scr")" | grep -qF "$m"; then
          return 0
        fi
      done
    fi
    sleep "$CONFIRM_SLEEP"
  done
  return 1
}

# payload_is_parked — true iff OUR unsubmitted payload is still sitting in the
# input box and the REPL is idle enough that an Enter would submit THAT payload and
# nothing else. This is the double-submit guard for the retry below (claude-plugins-fkgv).
#   busy / queued  → already submitted (phase-2); an Enter would submit the NEXT
#                    thing, not this one. Never parked.
#   interrupted    → an Enter answers the "what should Claude do instead?" prompt.
#   empty box      → the payload left the box (submitted). Nothing to resend.
#   foreign box text — a ghost suggested-prompt like `push it` (claude-plugins-ff6g)
#                    that reappears in an emptied box after a submit — is not ours;
#                    firing Enter on it would submit a phantom turn.
# "Ours" is the nonce on the box line (a small paste, including the [CALL_ID:] line
# a collapsed multi-line follow-up leaves as its first box line) or a `[Pasted text`
# placeholder ON the box line.
#   scrolled viewport ("Jump to bottom") → a capture we cannot trust as the live box.
#                    read_live is scroll-immune, so this should not be reachable;
#                    kept as a backstop because if it ever IS, then
#                    input_box_content's bare-`❯` fallback (repl-state.sh) could
#                    match a prior turn's "❯ [Pasted text #1 …" from history and we
#                    would fire Enter blind into the unseen live box — where a ghost
#                    suggested-prompt becomes a phantom turn (ff6g). Absence of the
#                    live box proves nothing; refuse.
#   box unchanged from the baseline — whatever is in there was in there BEFORE this
#                    paste, so it is not ours and an Enter would submit someone
#                    else's text. Reuse clears a dirty box and proves the clear took
#                    before pasting, and first contact waits for a freshly-drawn box,
#                    so in practice this only fires when the paste has not rendered
#                    yet — which is indistinguishable from "not ours" from here.
payload_is_parked() {
  local scr box
  scr=$(read_live) || return 1
  [[ -z "$scr" ]] && return 1
  printf '%s' "$scr" | grep -qF 'Jump to bottom' && return 1
  repl_looks_busy "$scr" && return 1
  repl_is_interrupted "$scr" && return 1
  box=$(input_box_content "$scr")
  [[ -z "$box" ]] && return 1
  [[ "$box" == "$BASELINE_BOX" ]] && return 1
  printf '%s' "$box" | grep -qF "$CALL_ID" && return 0
  printf '%s' "$box" | grep -qF '[Pasted text' && return 0
  return 1
}

# retry_landed — after the one Enter, poll (reusing the confirmation budget) for
# POSITIVE evidence the payload actually submitted, and echo the tier that proved it.
# Never treats absence as success, which is the whole point of this review round:
#   • the nonce reaching the transcript, OR
#   • a GOOD, non-scrolled read where the REPL is now busy/queued (the Enter kicked
#     off a turn), OR the box no longer holds our payload (it left the box).
# A read that FAILS or returns empty is NO evidence (NOT "the box emptied"), and a
# scrolled viewport is stale — both just keep polling, and time out to "not landed"
# so the caller gets undelivered (sent:true) rather than a fabricated success. The
# budget also covers a caller with no transcript path, whose only signal is the box
# clearing as the TUI re-renders after the Enter (claude-plugins-fkgv review 3).
retry_landed() {
  local i scr box t
  for ((i = 0; i < CONFIRM_TRIES; i++)); do
    for t in ${TRANSCRIPTS[@]+"${TRANSCRIPTS[@]}"}; do
      [[ -s "$t" ]] && grep -qF "$CALL_ID" "$t" 2>/dev/null && { echo "transcript"; return 0; }
    done
    scr=$(read_live) || scr=""
    if [[ -n "$scr" ]] && ! printf '%s' "$scr" | grep -qF 'Jump to bottom'; then
      if repl_looks_busy "$scr" || printf '%s' "$scr" | grep -qF "$QUEUED_HINT"; then
        echo "screen"; return 0
      fi
      box=$(input_box_content "$scr")
      if ! printf '%s' "$box" | grep -qF "$CALL_ID" && ! printf '%s' "$box" | grep -qF '[Pasted text'; then
        echo "screen"; return 0
      fi
    fi
    sleep "$CONFIRM_SLEEP"
  done
  return 1
}

# TIER ORDER: transcript, then PARKED, then screen.
#
# The transcript is definitive and goes first — it reads submitted bytes, not pixels.
#
# The parked check goes ahead of the screen tier because the two can read the SAME
# pixels and reach opposite verdicts, and only one of them is right. `[Pasted text`
# in the box is the parked state; `[Pasted text` in the scrollback is a submitted
# turn. When a tier that concludes "delivered" runs before the tier that concludes
# "arrived but never submitted", the false positive wins and the retry never fires —
# observed live on a reused surface at ~5% (claude-plugins-y4rl, recurrence of
# claude-plugins-fkgv). So the NEGATIVE interpretation is tested first: parked is a
# strictly stronger, box-scoped read of the same screen.
#
# Ordering it first is safe against submitting a payload twice because the box was
# proven EMPTY before this paste went out — cmux-reuse-surface.sh refuses to paste
# onto parked text and re-reads the box to prove its clear worked, and a first-contact
# REPL has never been typed into. So `[Pasted text` or our nonce in the box after the
# paste is OUR payload, not a leftover an Enter would submit instead.
CONFIRMED=""
RETRIED_ENTER=false
if confirmed_by_transcript; then
  CONFIRMED="transcript"
elif payload_is_parked; then
  # The transcript holds nothing AND the payload is still sitting unsubmitted in the
  # box: submit_key:return intermittently races the paste render and its return is
  # dropped (claude-plugins-fkgv; reproduced ~5% on collapsing multi-line payloads
  # into a reused surface, always recovered by one manual Enter). Fire that one
  # Enter, then re-verify.
  #
  # The settle (SUBMIT_SETTLE) is the same fence the split paste needs — an Enter
  # racing unfinished paste ingestion is the very race that parked the payload in
  # the first place.
  #
  # The Enter's own exit code is checked (like the other send-key call sites): if the
  # keystroke never left this machine, there is nothing to re-verify and claiming
  # success would be inventing it. The payload is still parked in the box, so this is
  # sent:true — the caller must not blindly re-deliver.
  sleep "$SUBMIT_SETTLE"
  if ! cmux send-key --surface "$SURFACE_REF" Enter >/dev/null 2>&1; then
    undelivered "pasted into surface $SURFACE_REF; the payload parked and the one Enter retry keystroke itself failed to send, so submission is unproven"
  fi
  RETRIED_ENTER=true
  # Re-verify by POSITIVE evidence only, polled over the budget. A read failure or a
  # scrolled viewport is not "the box emptied", and a slow re-render is not a failure.
  landed=$(retry_landed) \
    && CONFIRMED="$landed" \
    || undelivered "pasted into surface $SURFACE_REF; the payload parked unsubmitted and one Enter retry produced no evidence of submission within the confirmation budget — the nonce $CALL_ID never reached the transcript${TRANSCRIPTS[0]:+ (${TRANSCRIPTS[*]})} and the box was never observed to clear"
elif confirmed_by_screen; then
  CONFIRMED="screen"
else
  undelivered "pasted into surface $SURFACE_REF but nonce $CALL_ID never appeared in the callee's transcript${TRANSCRIPTS[0]:+ (${TRANSCRIPTS[*]})} or on its screen; treating delivery as lost"
fi

jq -nc --arg c "$CONFIRMED" --arg w "$WS_ID" --arg s "$SURF_ID" --argjson r "$RETRIED_ENTER" \
  '{delivered: true, sent: true, confirmed: $c, retried_enter: $r, workspace: $w, surface: $s}'
