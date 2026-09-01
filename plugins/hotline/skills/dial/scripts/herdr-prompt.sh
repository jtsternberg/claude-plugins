#!/usr/bin/env bash
# =============================================================================
# herdr Prompt: deliver a payload into a live herdr-hosted claude agent and PROVE
# it landed. The herdr counterpart of cmux-paste.sh, with the same JSON contract
# so dial.sh's delivery step reads identically for both transports.
#
# Usage:
#   herdr-prompt.sh --agent <name> --payload-file <path> --call-id <nonce>
#                   [--cwd <callee-cwd>] [--session <callee-session-id>]
#                   [--timeout <ms>] [--first-contact]
#
#   # → {"delivered":true,"sent":true,"confirmed":"transcript","agent":"…"}
#   # → {"delivered":false,"sent":false,"reason":"…"}   nothing reached the callee
#   # → {"delivered":false,"sent":true,"reason":"…"}    herdr took it; landing unproven
#
# Always exits 0 with JSON: whether a failed delivery means "retry elsewhere" or
# "fail the dial" is the caller's decision, not this script's. `sent` is what makes
# that decision safe — delivered:false with sent:false means the callee received
# nothing; with sent:TRUE the payload may already be in its input queue and
# re-delivering would run the work order twice.
#
# NO --wait ON THE SUBMIT, deliberately. `agent prompt --wait` blocks until the
# agent's lifecycle settles, which conflates two different questions: "did the
# payload arrive" (this script) and "has the callee answered" (wait-for-response.sh).
# Worse, herdr returns `agent_prompt_stalled` when a prompt from a non-working
# state produces no observed state change within 5s — and a callee that reads the
# work order and thinks quietly is exactly that. Treating a stall as a delivery
# failure would fail dials that worked. Submission is atomic without --wait
# (bracketed-paste aware, text and Enter together), which is all delivery needs.
#
# ONE PROOF TIER, NOT TWO. cmux confirms by transcript and falls back to the
# rendered screen. herdr has no equivalent second tier and must not pretend
# otherwise: the claude REPL is a full-screen alternate-screen TUI, and rows that
# leave the alternate screen never enter herdr's host scrollback — so `agent read`
# cannot see a payload the transcript missed. An unconfirmed delivery is therefore
# reported honestly as unconfirmed rather than blessed by a weaker check.
#
# FIRST CONTACT IS NOT A FOLLOW-UP, and --first-contact is what says so. Delivering
# the OPENING payload into an agent `herdr agent start` has only just returned from
# is the one delivery that can lose the whole work order, and it failed that way
# live, intermittently, under load (claude-plugins-7wze.12). Two things differ, and
# --first-contact addresses both:
#
#   1. READINESS IS A CLAIM, NOT A FACT — and until this flag existed nothing
#      re-established it. `agent start` reports `interactive_ready` once, at return;
#      the submit then happened on the strength of "a status string came back
#      non-empty", with no re-probe between. The cmux path's counterpart re-proves
#      the callee's input box is DRAWN immediately before pasting (`--wait-box`),
#      precisely because a launch-time signal is not a submit-time one. So on first
#      contact this settles, then polls `agent get` until herdr reports the agent
#      interactive-ready AND not `blocked` — and refuses with sent:false if it never
#      is, which leaves the caller free to re-dial because nothing went out.
#
#      `blocked` is refused for the same reason herdr-reuse-agent.sh refuses it, and
#      it is the likelier half of the live failure: a callee that came up on a
#      startup gate (a trust prompt) IS interactive — the dialog takes keystrokes —
#      so a payload submitted into it ANSWERS the gate and is consumed. No user turn,
#      no transcript, nothing to read. That is exactly the shape that was observed.
#
#   2. THE TRANSCRIPT DOES NOT EXIST YET. A follow-up's confirmation is one append
#      to a file already on disk; first contact needs the project directory and the
#      session's .jsonl CREATED, behind whatever else claude is doing on startup.
#      The flat 3s budget therefore reported landed payloads as unconfirmed under
#      load — a false delivered:false, which is safe but wrong. First contact gets a
#      larger budget instead, and waiting longer can never double-send.
#
# A SLASH-COMMAND FIRST CONTACT IS DELIVERED IN TWO WRITES, not one. `agent prompt`
# is atomic — text and Enter together — which is right for an ordinary payload and
# wrong for a slash command with a body beneath it: CC's TUI collapses the multi-line
# paste, the invocation stops being the literal start of the input, and the callee
# gets the work order as PLAIN TEXT with no ringing protocol — no STATUS, no call_id —
# so wait-for-response reads the silence as a reassigned callee and
# transcript-extract.sh exits 10 forever while the answer sits in the transcript
# (claude-plugins-fvhx). See DELIVER below for the two writes; WHEN to split is
# repl-state.sh's call, shared with cmux-paste.sh.
#
# WHAT THIS DELIBERATELY DOES NOT DO: retry the submit. A prevention-only fix leaves
# no path to a double-run. Re-sending after an unconfirmed submit cannot be made
# safe from here — an absent transcript does not distinguish "lost" from "sitting
# unsubmitted in the input box", and re-sending into the second case welds a second
# copy of the work order onto the first.
#
# THE PAYLOAD IS ON ARGV, and that is a real (bounded) exposure worth naming.
# `herdr agent prompt <target> <text>` takes its text as a positional argument and
# herdr 0.8.0 offers no file/stdin form (`herdr api` is read-only metadata). So for
# the lifetime of this one short-lived process the work order is visible to any
# local user through `ps` — the exposure cmux was reworked to eliminate
# (claude-plugins-86ka), narrowed here from "the whole callee session" to
# "sub-second". Accepted for Phase 1 and documented; revisit if herdr grows a
# file-based prompt form.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_SCRIPTS="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts"
# shellcheck source=../../../scripts/herdr-state.sh
source "$HOTLINE_SCRIPTS/herdr-state.sh"
# shellcheck source=../../../scripts/transcript-confirm.sh
source "$HOTLINE_SCRIPTS/transcript-confirm.sh"
# shellcheck source=../../../scripts/repl-state.sh
# For the split-delivery predicate, which cmux-paste.sh reads from the same place.
source "$HOTLINE_SCRIPTS/repl-state.sh"

AGENT=""
PAYLOAD_FILE=""
CALL_ID=""
CWD=""
SESSION_ID=""
TIMEOUT_MS=""
FIRST_CONTACT=false
# Same confirmation budget as cmux-paste.sh, and the same reasoning: generous
# enough for a transcript flush, short enough that a genuinely lost payload is
# reported in seconds rather than discovered a minute later by the response wait.
CONFIRM_SLEEP="${HOTLINE_PASTE_CONFIRM_SLEEP:-0.3}"
CONFIRM_TRIES="${HOTLINE_PASTE_CONFIRM_TRIES:-10}"
# First contact's budget is four times that (12s at the default cadence) because it
# waits on a FILE BEING CREATED rather than appended — see the header.
FIRST_CONFIRM_TRIES="${HOTLINE_HERDR_FIRST_CONFIRM_TRIES:-40}"
# Wall clock between `agent start`'s readiness claim and the first submit. The
# re-probe below cannot catch a claim that is merely PREMATURE — herdr says ready
# and means it — so this is the only lever against that half.
FIRST_SETTLE="${HOTLINE_HERDR_FIRST_SETTLE:-1}"
# How many times the first-contact gate re-reads `agent get` before giving up. At
# CONFIRM_SLEEP's cadence (shared deliberately: same "poll a settling thing"
# rationale) 20 tries is a 6s readiness budget.
READY_TRIES="${HOTLINE_HERDR_READY_TRIES:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)        AGENT="$2";        shift 2 ;;
    --payload-file) PAYLOAD_FILE="$2"; shift 2 ;;
    --call-id)      CALL_ID="$2";      shift 2 ;;
    --cwd)          CWD="$2";          shift 2 ;;
    --session)      SESSION_ID="$2";   shift 2 ;;
    --timeout)      TIMEOUT_MS="$2";   shift 2 ;;
    --first-contact) FIRST_CONTACT=true; shift ;;
    *)              shift ;;
  esac
done

PROMPT_SENT=false
undelivered() {  # undelivered <reason> [sent]
  jq -nc --arg reason "$1" --argjson sent "${2:-$PROMPT_SENT}" \
    '{delivered: false, sent: $sent, reason: $reason}'
  exit 0
}

[[ -z "$AGENT"        ]] && undelivered "no --agent name given"
[[ -z "$CALL_ID"      ]] && undelivered "no --call-id nonce given; delivery could not be confirmed even if it landed"
[[ -z "$PAYLOAD_FILE" ]] && undelivered "no --payload-file given"
[[ -s "$PAYLOAD_FILE" ]] || undelivered "payload file is missing or empty: $PAYLOAD_FILE"
herdr_on_path || undelivered "herdr is not on PATH"

# --- Is the agent still there? ----------------------------------------------
# A name is cleared when its agent exits, so "not found" here means the callee
# died between launch and delivery. Reporting that as a delivery failure with
# sent:false is the whole point: nothing reached anyone, so the caller is free to
# re-dial.
# ONE READ, BOTH FACTS — the lifecycle state and herdr's `interactive_ready`. The
# readiness half used to be thrown away here; see FIRST CONTACT in the header.
herdr_agent_probe "$AGENT"
AGENT_STATUS="$HERDR_AGENT_STATUS"
AGENT_READY="$HERDR_AGENT_READY"
AGENT_PANE="$HERDR_AGENT_PANE"
if [[ -z "$AGENT_STATUS" ]]; then
  undelivered "herdr agent $AGENT could not be read (${HERDR_CLI_ERR:-no such live agent}); the callee may have exited before delivery" false
fi

# --- First contact only: settle, then re-establish readiness. -----------------
# Nothing has been submitted yet and nothing will be until this passes, so every
# exit from here is sent:false — the caller is free to re-dial.
#
# A follow-up skips this deliberately. Its agent has already taken a prompt and
# answered one, which is a stronger fact than any probe, and its refusals live in
# herdr-reuse-agent.sh where the caller can still fall back.
if $FIRST_CONTACT; then
  sleep "$FIRST_SETTLE"
  ready_try=0
  while :; do
    # An ABSENT interactive_ready is permission to proceed, not a failure: gating on
    # a field a future herdr might stop reporting would turn "unproven" into
    # "impossible". Only an explicit `false` holds the payload back.
    if [[ "$AGENT_READY" != "false" && "$AGENT_STATUS" != "blocked" ]]; then
      break
    fi
    ready_try=$((ready_try + 1))
    if [[ $ready_try -ge $READY_TRIES ]]; then
      if [[ "$AGENT_STATUS" == "blocked" ]]; then
        undelivered "herdr agent $AGENT is 'blocked' before first contact — \`herdr agent attach $AGENT\` shows what it is asking. It is waiting on INPUT (a startup trust prompt, or a permission gate), and a work order submitted into that dialog would ANSWER it and vanish without ever becoming a turn. Nothing was submitted: clear the gate and re-dial, or dial with HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 (a real trust decision, see the plugin README)." false
      fi
      undelivered "herdr agent $AGENT never reported interactive_ready within the readiness budget (last state '$AGENT_STATUS') — \`herdr agent attach $AGENT\` shows what is actually in the pane. \`agent start\` claimed the REPL was ready; it is not now, and a payload submitted into whatever IS there would be lost silently. Nothing was submitted, so re-dialing is safe." false
    fi
    sleep "$CONFIRM_SLEEP"
    herdr_agent_probe "$AGENT"
    AGENT_STATUS="$HERDR_AGENT_STATUS"
    AGENT_READY="$HERDR_AGENT_READY"
    AGENT_PANE="$HERDR_AGENT_PANE"
    if [[ -z "$AGENT_STATUS" ]]; then
      undelivered "herdr agent $AGENT stopped resolving while waiting for it to become interactive-ready (${HERDR_CLI_ERR:-no such live agent}); the callee exited before first contact" false
    fi
  done
  CONFIRM_TRIES="$FIRST_CONFIRM_TRIES"
fi

# --- Which transcripts could carry the proof? -------------------------------
# Derived BEFORE the submit, so the confirmation loop below starts polling the
# instant the payload is away. Both spellings of the cwd — see the shared helper.
TRANSCRIPTS=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] && TRANSCRIPTS+=("$_p")
done < <(hotline_transcript_candidates "$CWD" "$SESSION_ID")

# --- Deliver. ---------------------------------------------------------------
# ONE submit for an ordinary payload; TWO writes for a slash command that has a body
# beneath it (see the header for why one would lose the whole work order). The
# predicate is repl-state.sh's, shared with cmux-paste.sh, because the two transports
# must never disagree about WHEN to split — they already did once, which is the bug
# this fixes.
#
# The two writes, in herdr's primitives:
#
#   1. `pane send-text <pane> <invocation line>` — literal text with NO newline, so
#      the box now STARTS with `/…` and nothing has been submitted. The newline is
#      omitted deliberately: sending it here would submit the invocation ALONE.
#   2. `agent prompt <agent> <newline + body>` — herdr's atomic, bracketed-paste-aware
#      submit does the half that has to survive multiple lines. The body's placeholder
#      expands back inside the command args on Enter, and head + newline + body
#      reconstructs the payload.
#
# Probe-verified live on CC 2.1.251 / herdr 0.8.0: split → the harness answers
# `Unknown command:` and lists every body line under `Args from unknown skill:`, so
# the slash parsed and the body arrived as its args; one atomic `agent prompt` of the
# same six lines → answered as ordinary prose, no command expansion at all.
#
# `pane send-text` addresses a PANE while `agent prompt` addresses the AGENT, so a
# split needs both handles. The pane comes off the same `agent get` the probe above
# already made; without it the split cannot be performed, and performing the
# UNSPLIT delivery instead would be worse than refusing — the nonce would reach the
# transcript, delivery would report confirmed, and the caller would then wait forever
# for a protocol that never engaged.
PROMPT_TEXT=$(cat "$PAYLOAD_FILE")
if hotline_payload_needs_split_delivery "$PAYLOAD_FILE"; then
  if [[ -z "$AGENT_PANE" ]]; then
    undelivered "herdr agent $AGENT reports no pane_id, and this payload is a slash command with a body — which has to be delivered as an invocation line (\`pane send-text\`) followed by the body (\`agent prompt\`), or the slash command never parses and the callee reads the work order as plain text. Nothing was submitted; re-dial is safe." false
  fi
  if ! herdr_cli pane send-text "$AGENT_PANE" "$(sed -n '1p' "$PAYLOAD_FILE")"; then
    undelivered "herdr pane send-text $AGENT_PANE failed while placing the invocation line for agent $AGENT: ${HERDR_CLI_ERR:-no diagnostic}. Nothing was submitted." false
  fi
  # The invocation line is in the callee's box now; a later failure must not claim
  # nothing was sent.
  PROMPT_SENT=true
  PROMPT_TEXT=$'\n'"$(sed -n '2,$p' "$PAYLOAD_FILE")"
fi

PROMPT_ARGS=(agent prompt "$AGENT" "$PROMPT_TEXT")
[[ -n "$TIMEOUT_MS" ]] && PROMPT_ARGS+=(--timeout "$TIMEOUT_MS")
if ! herdr_cli "${PROMPT_ARGS[@]}"; then
  # herdr validates the target and the keys before writing any bytes, so a refusal
  # here means the callee's input queue is untouched BY THIS CALL — which is the whole
  # truth only on the unsplit path. After a split's first write the invocation line is
  # already in the box, so the honest answer is whatever PROMPT_SENT holds.
  undelivered "herdr agent prompt $AGENT failed: ${HERDR_CLI_ERR:-no diagnostic}" "$PROMPT_SENT"
fi
# From here the payload may be in the callee's input queue whatever we observe.
PROMPT_SENT=true

# --- Did the callee actually get it? ----------------------------------------
# herdr's ok is its own ack, not delivery proof — the same no-trusting-exit-codes
# rule cmux delivery lives by. The nonce reaching the callee's transcript is proof;
# nothing else here is.
if [[ ${#TRANSCRIPTS[@]} -eq 0 ]]; then
  undelivered "submitted to herdr agent $AGENT but delivery is unconfirmable: no transcript path could be derived (need both --cwd and --session). Read the callee's transcript for call_id $CALL_ID before re-dialing — a re-dial would run the work order twice."
fi

if hotline_confirm_nonce_in_transcripts "$CALL_ID" "$CONFIRM_TRIES" "$CONFIRM_SLEEP" \
     "${TRANSCRIPTS[@]}"; then
  jq -nc --arg a "$AGENT" --arg s "${AGENT_STATUS:-unknown}" \
    '{delivered: true, sent: true, confirmed: "transcript", agent: $a, agent_status: $s}'
  exit 0
fi

undelivered "submitted to herdr agent $AGENT but nonce $CALL_ID never appeared in the callee's transcript (${TRANSCRIPTS[*]}) within the confirmation budget. There is no screen fallback for herdr — a claude REPL runs on the terminal's alternate screen, so herdr's scrollback cannot see what the transcript missed. Read the transcript yourself before re-dialing."
