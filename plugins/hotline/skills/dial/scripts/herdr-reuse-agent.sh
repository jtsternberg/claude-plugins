#!/usr/bin/env bash
# =============================================================================
# herdr Reuse Agent: send a follow-up INTO the herdr agent a session already
# lives in, instead of starting a second callee.
#
# The herdr counterpart of cmux-reuse-surface.sh, and deliberately a fraction of
# its size. cmux has to RESOLVE a host (a surface handle that can silently
# retarget), prove a claude REPL is still drawn on it, read its input box, and
# sometimes clear that box with a real interrupt — because a cmux surface is a
# rectangle of pixels that anything could have taken over. herdr has none of that
# surface area: the NAMED AGENT IS THE SESSION. `herdr agent prompt <name>`
# re-targets it by name, submission is atomic and bracketed-paste aware, and
# `herdr agent get <name>` answers "is it still there" outright. So this script is
# three steps: probe, submit, prove.
#
# Verified live on herdr 0.8.0, and the reason this path exists at all: a
# follow-up is just another `agent prompt` to the same live name. Context
# continues and BOTH exchanges land in one session and one transcript ("remember
# 42" → later "what number?" → "42"). A finished, unfocused agent reports
# `status: done` rather than `idle` and still re-accepts a prompt.
#
# Usage:
#   herdr-reuse-agent.sh --agent <name> --session <callee-session-id>
#                        (--prompt <text> | --prompt-file <path>)
#                        [--cwd <callee-cwd>]
#   # → {"call_dir":"…","delivery":"prompt","confirmed":"transcript"}
#   #     re-targeted the live agent and proved the payload landed
#   # → {"fallback":"fresh","reason":"…"}
#   #     refused BEFORE anything was submitted, so a fresh launch is safe
#   # → {"undelivered":true,"reason":"…","call_dir":…,"prompt_file":…}
#   #     the submit went out and could not be confirmed. NOT a fallback: the
#   #     payload may already be in the callee's queue, so re-delivering it
#   #     elsewhere would run the work order twice.
#
# --prompt-file is preferred: it keeps the payload out of argv on the way in.
# (The last hop still puts it on argv — `herdr agent prompt` takes its text
# positionally and herdr 0.8.0 offers no file form. See herdr-prompt.sh.)
#
# A FRESH NONCE EVERY TURN, which is the one piece of cmux's reuse machinery that
# does carry over. The callee's transcript keeps every prior exchange's `STATUS:`
# lines, so a follow-up that reused the previous nonce would read the PRIOR turn's
# completion as this one's. Minted through repl-state.sh, same as every launcher.
#
# WHAT THIS SCRIPT DOES NOT DO — and must not grow:
#   • No superseded-host cleanup. The same agent is reused, so nothing is
#     orphaned and there is nothing to close (close-superseded-surface.sh exists
#     because a cmux follow-up that opened a NEW surface stranded the old one).
#   • No input-box gating, no Ctrl-C, no screen read. herdr cannot see a claude
#     REPL's box at all (alternate-screen TUI) and does not need to: submission is
#     atomic, and a busy callee QUEUES the prompt rather than welding it onto
#     leftover text.
#   • No re-wrapping in the ringing invocation. That is first contact's job; this
#     session already ran it. dial.sh hands us the raw message, and re-invoking
#     the slash command would re-run first-contact setup inside a live call.
#
# TWO STATES REFUSE THE REUSE, and both refuse before submitting anything:
#   gone     — no live agent answers to the name. herdr clears a name when its
#              agent exits, so this is how a dead callee reports itself.
#   blocked  — the callee is waiting on INPUT (a permission gate, or a genuine
#              question). This is the herdr analogue of cmux's post-interrupt
#              "what should Claude do instead?" refusal: a work order submitted
#              into that state ANSWERS the gate instead of starting a turn.
# Both come back as {"fallback":"fresh"} with the state in the reason, because
# what to do about it is the caller's decision, not this script's.
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
# shellcheck source=../../../scripts/herdr-state.sh
source "$HOTLINE_SCRIPTS/herdr-state.sh"

AGENT=""
SESSION_ID=""
PROMPT=""
PROMPT_FILE=""
CWD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)       AGENT="$2";       shift 2 ;;
    --session)     SESSION_ID="$2";  shift 2 ;;
    --prompt)      PROMPT="$2";      shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd)         CWD="$2";         shift 2 ;;
    *)             shift ;;
  esac
done

fallback_fresh() {  # fallback_fresh <reason>
  jq -nc --arg reason "$1" '{fallback: "fresh", reason: $reason}'
  exit 0
}

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { jq -nc --arg e "--prompt-file does not exist: $PROMPT_FILE" '{error:$e}'; exit 1; }
  PROMPT=$(cat "$PROMPT_FILE")
fi
[[ -z "$PROMPT" ]] && { echo '{"error": "No --prompt or --prompt-file provided"}'; exit 1; }

[[ -z "$AGENT" ]] && fallback_fresh "no herdr agent name provided (the cache holds no host handle for this session)"
herdr_on_path || fallback_fresh "herdr is not on PATH, so no live agent can be re-targeted"

# --- Is the agent still there, and will it take a prompt? --------------------
# The whole liveness question, in one read. "Survives a detach" is not "survives
# forever": the user can quit the callee, close its pane, or restart the herdr
# server, and every one of those clears the name.
herdr_agent_status "$AGENT"
AGENT_STATUS="$HERDR_AGENT_STATUS"
if [[ -z "$AGENT_STATUS" ]]; then
  fallback_fresh "no live herdr agent answers to the cached host handle '$AGENT' (${HERDR_CLI_ERR:-no such agent}) — it has exited, or the handle belongs to a different transport"
fi
if [[ "$AGENT_STATUS" == "blocked" ]]; then
  fallback_fresh "herdr agent $AGENT is 'blocked' — it is waiting on input (a permission gate or a question), and a follow-up submitted now would answer that instead of starting a turn. \`herdr agent attach $AGENT\` shows what it is asking"
fi

# --- Wire a call dir exactly as the herdr launcher leaves one. ---------------
# Same backend-agnostic contract, minus the launch: wait-for-response.sh reads
# transport.txt first and then addresses this agent by name, so a reused call is
# indistinguishable downstream from a first-contact one.
#
# HOTLINE_CALL_HOME overrides the base dir (default /tmp) so test suites can own
# and wipe every call dir instead of littering /tmp (claude-plugins-cjgn).
CALL_DIR=$(mktemp -d "${HOTLINE_CALL_HOME:-/tmp}/hotline-call-XXXXX")
echo herdr    > "$CALL_DIR/transport.txt"
echo "$AGENT" > "$CALL_DIR/herdr_agent.txt"
# See herdr-call-async.sh's WHY NOTHING IS CLOSED. Doubly true here: the agent
# predates this call, so closing it would end a conversation the caller may not
# be finished with.
echo true     > "$CALL_DIR/keep_workspace.txt"
if [[ -n "$SESSION_ID" ]]; then
  echo "$SESSION_ID" > "$CALL_DIR/session_id.txt"
  echo "$SESSION_ID" > "$CALL_DIR/session_id_preset.txt"
fi
# CANONICALIZED, for the same reason the launcher canonicalizes it: Claude Code
# encodes the cwd it RESOLVED, so a callee under a symlinked path writes its
# transcript under the realpath spelling. Every consumer derives the transcript
# path from this file. (Delivery and the wait both try both spellings anyway —
# this is the half that makes them agree by construction.)
if [[ -n "$CWD" ]]; then
  CWD_CANON=$(cd "$CWD" 2>/dev/null && pwd -P) || CWD_CANON="$CWD"
  echo "$CWD_CANON" > "$CALL_DIR/cwd.txt"
fi

CALL_ID=$(hotline_mint_call_id)
echo "$CALL_ID" > "$CALL_DIR/call_id.txt"

# 0600 inside a 0700 mktemp dir, named pending_paste.md like every other path's
# undelivered prompt so one recovery instruction covers all of them. Removed the
# moment delivery is confirmed — the callee's transcript is the record; this file
# is only the vehicle.
PAYLOAD_FILE="$CALL_DIR/pending_paste.md"
( umask 077; hotline_inject_call_id "$CALL_ID" "$PROMPT" > "$PAYLOAD_FILE" )
chmod 600 "$PAYLOAD_FILE" 2>/dev/null || true

# --- One submit, then proof. -------------------------------------------------
# herdr-prompt.sh owns both halves — the same script first contact uses — so
# there is exactly one herdr delivery path to reason about and one place a new
# landing signal has to be taught.
DELIVER_ARGS=(--agent "$AGENT" --payload-file "$PAYLOAD_FILE" --call-id "$CALL_ID")
[[ -n "$CWD"        ]] && DELIVER_ARGS+=(--cwd "$CWD")
[[ -n "$SESSION_ID" ]] && DELIVER_ARGS+=(--session "$SESSION_ID")
DELIVERY=$(bash "$SCRIPT_DIR/herdr-prompt.sh" "${DELIVER_ARGS[@]}" 2>/dev/null)

if [[ "$(jq -r '.delivered // false' <<<"$DELIVERY" 2>/dev/null)" != "true" ]]; then
  DELIVERY_REASON=$(jq -r '.reason // "delivery failed with no reason"' <<<"$DELIVERY" 2>/dev/null)
  if [[ "$(jq -r '.sent // false' <<<"$DELIVERY" 2>/dev/null)" == "true" ]]; then
    # herdr ACCEPTED the submit and we could not prove where it went. This must
    # NOT become fallback:fresh: the caller answers that by starting a second
    # callee and re-delivering the same prompt, so a payload that actually landed
    # runs twice. The call dir and pending_paste.md stay put — that prompt is the
    # only copy left, and it is what a human needs in order to decide.
    jq -nc --arg reason "$DELIVERY_REASON" --arg dir "$CALL_DIR" --arg pf "$PAYLOAD_FILE" \
      '{undelivered: true, reason: $reason, call_dir: $dir, prompt_file: $pf}'
    exit 0
  fi
  # Nothing reached the callee (a name that stopped resolving between the probe
  # and the submit, or a refusal herdr validated before writing bytes), so a
  # fresh callee is safe. The call dir must go: the waiter would otherwise poll
  # for a nonce that was never submitted.
  rm -rf "$CALL_DIR"
  fallback_fresh "$DELIVERY_REASON"
fi

rm -f "$PAYLOAD_FILE"

jq -nc --arg dir "$CALL_DIR" --arg agent "$AGENT" --arg st "$AGENT_STATUS" \
  --arg confirmed "$(jq -r '.confirmed // empty' <<<"$DELIVERY" 2>/dev/null)" \
  '{call_dir: $dir, delivery: "prompt", confirmed: $confirmed,
    agent: $agent, agent_status: $st}'
