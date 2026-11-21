#!/usr/bin/env bash
# =============================================================================
# Notify Caller: decide whether a callee should push "your call resolved" into the
# caller's live Claude Code session, and print who to send it to.
#
# A waiter (wait-for-response.sh) reads the full answer for the caller. Its process
# alone does not wake an idle Codex caller: that caller must keep waiting in its
# turn or arm scripts/completion-watch.py. This script preserves Claude behavior.
# A caller that never started one, or whose waiter died,
# never hears — a WORK_COMPLETE once sat unread until the human noticed it. The
# push is Claude Code's cross-session messaging, and only a model can send it
# (SendMessage is a tool; no CLI verb exists), so the callee sends and this script
# is the deterministic part in front of that send.
#
# Usage:
#   notify-caller.sh --caller-session <id> --call-id <nonce> --status <STATUS> [--detail <ask>]
#
# --detail is the one-line ask or outcome behind the status (a blocked ending's
# question); it goes into the notice and into the dedupe key.
#
# <STATUS> is any UPPER_SNAKE word but WORK_IN_PROGRESS. Its class comes from the
# call's status_classes.txt (scripts/status-classes.sh): the built-ins, plus what
# the caller declared at dial time. A word in neither still notifies, as class
# unknown, so a convention the caller never declared is not dropped silently.
#
# Prints ONE JSON line and exits 0 for every outcome but a usage error (exit 2):
#   {"send":true,"to":"<name>","call_dir":"<dir or empty>","status":"<WORD>","class":"<class>","message":"…"}
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
#   4. Once per (nonce, status, detail) within HOTLINE_NOTIFY_REPEAT_SECONDS, via
#      an atomic mkdir under ~/.agents-hotline/notified/<nonce>/. A long-running
#      callee reports many times per call, so a new status or a new ask always
#      notifies. An identical repeat inside the window does not: re-running this
#      check for the same ending, or a callee re-ending on the same status after
#      each nudge, would otherwise push the same notice into the caller again and
#      again. Taken last, so a refusal above never spends the key.
#
# Environment:
#   HOTLINE_CLAUDE_BIN — the claude executable (default `claude`).
#   HOTLINE_NOTIFY_REPEAT_SECONDS — how long an identical notice stays suppressed
#     (default 1800). Past it, the same still-unanswered ask notifies again.
# =============================================================================
set -uo pipefail

CALLER_SESSION=""
CALL_ID=""
STATUS=""
DETAIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="${2-}"; shift 2 ;;
    --call-id)        CALL_ID="${2-}";        shift 2 ;;
    --status)         STATUS="${2-}";         shift 2 ;;
    --detail)         DETAIL="${2-}";         shift 2 ;;
    *) echo "notify-caller: unknown argument: $1" >&2; exit 2 ;;
  esac
done

usage_error() { echo "notify-caller: $1" >&2; exit 2; }
[[ -n "$CALLER_SESSION" ]] || usage_error "--caller-session is required"
[[ "$CALL_ID" =~ ^[A-Za-z0-9_-]+$ ]] || usage_error "--call-id must be the call's nonce"
[[ "$STATUS" =~ ^[A-Z][A-Z0-9_]*$ && "$STATUS" != WORK_IN_PROGRESS ]] \
  || usage_error "--status must be the UPPER_SNAKE STATUS word you will end on (not WORK_IN_PROGRESS), got '${STATUS}'"
# shellcheck source=../../../scripts/status-classes.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/status-classes.sh"
REPEAT_SECONDS="${HOTLINE_NOTIFY_REPEAT_SECONDS:-1800}"
[[ "$REPEAT_SECONDS" =~ ^[0-9]+$ ]] || REPEAT_SECONDS=1800

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

# 4. Once per (nonce, status, detail) within the repeat window. cksum, not
#    shasum/sha256sum: it is POSIX, so the key is the same on macOS and Linux.
KEY=$(printf '%s\n%s' "$STATUS" "$DETAIL" | cksum | awk '{print $1 "-" $2}')
MARK="$STATE_DIR/notified/$CALL_ID/$STATUS-$KEY"
mkdir -p "$STATE_DIR/notified/$CALL_ID" 2>/dev/null
NOW=$(date +%s)
if ! mkdir "$MARK" 2>/dev/null; then
  SENT_AT=$(tr -dc '0-9' < "$MARK/at" 2>/dev/null)
  if [[ -n "$SENT_AT" ]] && (( NOW - SENT_AT < REPEAT_SECONDS )); then
    skip already-notified
  fi
  # Expired (or written without a time): re-take it, still through mkdir, so two
  # concurrent checks cannot both win.
  rm -rf "$MARK" 2>/dev/null
  mkdir "$MARK" 2>/dev/null || skip already-notified
fi
echo "$NOW" > "$MARK/at"

CLASS=$(hotline_status_class "$STATUS" "${CALL_DIR:+$CALL_DIR/$HOTLINE_STATUS_FILE_NAME}")
LABEL="STATUS: $STATUS"
hotline_status_is_builtin "$STATUS" || LABEL+=" (class: $CLASS)"

if [[ -n "$CALL_DIR" ]]; then
  WHERE="Call dir: $CALL_DIR — wait-for-response.sh on it returns the full answer."
else
  WHERE="Its call dir is the hotline-call-* dir whose call_id.txt holds $CALL_ID."
fi
jq -nc --arg to "$TO" --arg d "$CALL_DIR" --arg st "$STATUS" --arg cl "$CLASS" \
  --arg m "hotline: call_id=$CALL_ID resolved — $LABEL${DETAIL:+ — $DETAIL}. $WHERE" \
  '{send:true, to:$to, call_dir:$d, status:$st, class:$cl, message:$m}'
