#!/usr/bin/env bash
# =============================================================================
# herdr Prompt: deliver a payload into a live herdr-hosted claude agent and PROVE
# it landed. The herdr counterpart of cmux-paste.sh, with the same JSON contract
# so dial.sh's delivery step reads identically for both transports.
#
# Usage:
#   herdr-prompt.sh --agent <name> --payload-file <path> --call-id <nonce>
#                   [--cwd <callee-cwd>] [--session <callee-session-id>]
#                   [--timeout <ms>]
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

AGENT=""
PAYLOAD_FILE=""
CALL_ID=""
CWD=""
SESSION_ID=""
TIMEOUT_MS=""
# Same confirmation budget as cmux-paste.sh, and the same reasoning: generous
# enough for a transcript flush, short enough that a genuinely lost payload is
# reported in seconds rather than discovered a minute later by the response wait.
CONFIRM_TRIES="${HOTLINE_PASTE_CONFIRM_TRIES:-10}"
CONFIRM_SLEEP="${HOTLINE_PASTE_CONFIRM_SLEEP:-0.3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)        AGENT="$2";        shift 2 ;;
    --payload-file) PAYLOAD_FILE="$2"; shift 2 ;;
    --call-id)      CALL_ID="$2";      shift 2 ;;
    --cwd)          CWD="$2";          shift 2 ;;
    --session)      SESSION_ID="$2";   shift 2 ;;
    --timeout)      TIMEOUT_MS="$2";   shift 2 ;;
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
herdr_agent_status "$AGENT"
AGENT_STATUS="$HERDR_AGENT_STATUS"
if [[ -z "$AGENT_STATUS" ]]; then
  undelivered "herdr agent $AGENT could not be read (${HERDR_CLI_ERR:-no such live agent}); the callee may have exited before delivery" false
fi

# --- Which transcripts could carry the proof? -------------------------------
# Derived BEFORE the submit, so the confirmation loop below starts polling the
# instant the payload is away. Both spellings of the cwd — see the shared helper.
TRANSCRIPTS=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] && TRANSCRIPTS+=("$_p")
done < <(hotline_transcript_candidates "$CWD" "$SESSION_ID")

# --- Deliver. ---------------------------------------------------------------
PROMPT_TEXT=$(cat "$PAYLOAD_FILE")
PROMPT_ARGS=(agent prompt "$AGENT" "$PROMPT_TEXT")
[[ -n "$TIMEOUT_MS" ]] && PROMPT_ARGS+=(--timeout "$TIMEOUT_MS")
if ! herdr_cli "${PROMPT_ARGS[@]}"; then
  # Nothing was submitted: herdr validates the target and the keys before writing
  # any bytes, so a refusal here means the callee's input queue is untouched.
  undelivered "herdr agent prompt $AGENT failed: ${HERDR_CLI_ERR:-no diagnostic}" false
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
