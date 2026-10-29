#!/usr/bin/env bash
# =============================================================================
# Notify Caller: decide whether a callee should push "your call resolved" into the
# caller's live Claude Code session, and print who to send it to.
#
# A waiter (wait-for-response.sh) reads the full answer for the caller.
# A caller that never started one, or whose waiter died,
# never hears — a WORK_COMPLETE once sat unread until the human noticed it. The
# push is Claude Code's cross-session messaging, and only a model can send it
# (SendMessage is a tool; no CLI verb exists), so the callee sends and this script
# is the deterministic part in front of that send.
#
# Usage:
#   notify-caller.sh --caller-session <id> --call-id <nonce> --status <STATUS>
#
# Prints ONE JSON line and exits 0 for every outcome but a usage error (exit 2):
#   {"send":true,"to":"<session name>","call_dir":"<dir or empty>","message":"…"}
#   {"send":false,"reason":"<why>"}
# Reasons: waiter-live, claude-unavailable, caller-not-live,
# caller-name-ambiguous, already-notified.
#
# Decisions, in order:
#   1. A live waiter on this call (call_dir/waiter.pid running wait-for-response.sh
#      with this call dir among its args) delivers the answer itself, so a notice would only duplicate it. The call
#      dir comes from the caller's own session cache, matched on last_call_id; an
#      older exchange's nonce is no longer there, which only means the notice goes
#      out without a call dir.
#   2. The caller must be a live session in `claude agents --json` (the documented
#      scripting listing; it maps sessionId → the name ListAgents/SendMessage
#      address). A Codex thread id, a caller on another machine, or an exited
#      session is absent → nothing is sent.
#   3. Its name must be unique among live sessions: SendMessage addresses by name,
#      and this listing has no ref to disambiguate with.
#   4. Once per nonce, via an atomic mkdir under ~/.agents-hotline/notified. Taken
#      last, so a refusal above never spends the nonce.
#
# Environment:
#   HOTLINE_CLAUDE_BIN — the claude executable (default `claude`).
# =============================================================================
set -uo pipefail

CALLER_SESSION=""
CALL_ID=""
STATUS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="${2-}"; shift 2 ;;
    --call-id)        CALL_ID="${2-}";        shift 2 ;;
    --status)         STATUS="${2-}";         shift 2 ;;
    *) echo "notify-caller: unknown argument: $1" >&2; exit 2 ;;
  esac
done

usage_error() { echo "notify-caller: $1" >&2; exit 2; }
[[ -n "$CALLER_SESSION" ]] || usage_error "--caller-session is required"
[[ "$CALL_ID" =~ ^[A-Za-z0-9_-]+$ ]] || usage_error "--call-id must be the call's nonce"
case "$STATUS" in
  DONE|WORK_COMPLETE|OUT_OF_SCOPE|AWAITING_REVIEW|BLOCKED) ;;
  *) usage_error "--status must be a resolving STATUS (DONE, WORK_COMPLETE, OUT_OF_SCOPE, AWAITING_REVIEW, BLOCKED), got '${STATUS}'" ;;
esac

skip() { jq -nc --arg r "$1" '{send:false, reason:$r}'; exit 0; }

STATE_DIR="$HOME/.agents-hotline"
CACHE_FILE="$STATE_DIR/sessions/$CALLER_SESSION.json"

# 1. The caller's call dir, and whether a waiter is already on it.
CALL_DIR=""
if [[ -f "$CACHE_FILE" ]]; then
  CALL_DIR=$(jq -r --arg n "$CALL_ID" \
    '[.connections // {} | .[] | select(.last_call_id == $n) | .last_call_dir // empty] | first // empty' \
    "$CACHE_FILE" 2>/dev/null) || CALL_DIR=""
fi
if [[ -n "$CALL_DIR" && -s "$CALL_DIR/waiter.pid" ]]; then
  WPID=$(tr -dc '0-9' < "$CALL_DIR/waiter.pid")
  # A recycled pid can land on another call's waiter, so the process must be a
  # waiter AND name this call dir. Matched on the dir's mktemp basename, since the
  # caller may have passed the path relative or with a trailing slash.
  WCMD=""
  [[ -n "$WPID" ]] && WCMD=$(ps -p "$WPID" -o command= 2>/dev/null)
  CALL_BASE=$(basename "$CALL_DIR")
  if [[ "$WCMD" == *wait-for-response.sh* ]] \
     && [[ " $WCMD " =~ [[:space:]/]"$CALL_BASE"/?[[:space:]] ]]; then
    skip waiter-live
  fi
fi

# 2-3. The caller as a live, uniquely named session.
AGENTS=$("${HOTLINE_CLAUDE_BIN:-claude}" agents --json 2>/dev/null) || skip claude-unavailable
jq -e 'type == "array"' <<<"$AGENTS" >/dev/null 2>&1 || skip claude-unavailable
TO=$(jq -r --arg s "$CALLER_SESSION" \
  '[.[] | select(.sessionId == $s) | .name // empty] | first // empty' <<<"$AGENTS")
[[ -n "$TO" ]] || skip caller-not-live
[[ "$(jq --arg n "$TO" '[.[] | select(.name == $n)] | length' <<<"$AGENTS")" -eq 1 ]] \
  || skip caller-name-ambiguous

# 4. Once per nonce.
mkdir -p "$STATE_DIR/notified" 2>/dev/null
mkdir "$STATE_DIR/notified/$CALL_ID" 2>/dev/null || skip already-notified

if [[ -n "$CALL_DIR" ]]; then
  WHERE="Call dir: $CALL_DIR — wait-for-response.sh on it returns the full answer."
else
  WHERE="Its call dir is the hotline-call-* dir whose call_id.txt holds $CALL_ID."
fi
jq -nc --arg to "$TO" --arg d "$CALL_DIR" \
  --arg m "hotline: call_id=$CALL_ID resolved — STATUS: $STATUS. $WHERE" \
  '{send:true, to:$to, call_dir:$d, message:$m}'
