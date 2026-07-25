#!/usr/bin/env bash
# =============================================================================
# preempt-check.sh — was the callee handed a different task mid-call?
#
# Usage: preempt-check.sh <transcript.jsonl> <call_id_nonce>
#
# Exit:
#   0 — PREEMPTED. A genuine human prompt arrived in the callee's session AFTER
#       our nonce turn, so it will never emit STATUS for our call. The preempting
#       prompt (truncated) goes to stdout.
#   1 — not preempted (still working, or our nonce turn isn't in the transcript
#       yet, so there is nothing to be preempted from).
#   2 — usage / unreadable transcript.
#
# WHY THIS EXISTS (claude-plugins-dvjo)
# A cmux-routed call lands in a VISIBLE surface, and a visible surface is one the
# human can type into — that is the point of side-by-side placement, not a misuse.
# The moment they give that session another task, our STATUS line is never coming.
# Before this, wait-for-response.sh stayed patient for the full 1800s cmux timeout
# with no way to distinguish "still working" from "will never answer". Observed for
# real: a dotfiles session finished its work order, was reassigned to a migration,
# and the caller's waiter had to be killed by hand.
#
# WHAT COUNTS AS PREEMPTION
# A `type:"user"` record after our nonce turn that carries actual prose. Which
# means these are deliberately NOT preemption:
#   - tool_result records (no text blocks → no prose)
#   - isMeta / isSidechain / isCompactSummary / isVisibleInTranscriptOnly records
#   - our own nonce turn, or a replay of it
#   - anything BEFORE our nonce turn (the ringing prompt, a prior call in the
#     same session)
# And these ARE, because both mean our turn will not complete:
#   - a new human prompt, including one typed as a slash command
#   - `[Request interrupted by user …]`
#
# Client-side commands (/model, /clear) are recorded as type:"system"
# subtype:"local_command", not as user records, so they fall out of scope here for
# free — which is right for /model, and a known miss for /clear (it would destroy
# the context our call depends on, but the timeout still catches that).
# =============================================================================
set -uo pipefail

TRANSCRIPT="${1:-}"
NONCE="${2:-}"

if [[ -z "$TRANSCRIPT" || -z "$NONCE" ]]; then
  echo "usage: preempt-check.sh <transcript.jsonl> <call_id_nonce>" >&2
  exit 2
fi
[[ -r "$TRANSCRIPT" ]] || { echo "transcript not readable: $TRANSCRIPT" >&2; exit 2; }

# One slurp pass: locate our nonce turn, then find the first genuine human prompt
# after it. `.message.content` is either a bare string or an array of blocks; only
# text blocks contribute prose, which is what excludes tool_result records.
PARSED=$(jq -s -c --arg nonce "$NONCE" '
  (map(.type == "user"
       and ((.message.content | tostring) | test("CALL_ID: " + $nonce)))
   | index(true)) as $ui
  | if $ui == null then
      {preempted: false, prompt: ""}
    else
      ([ .[$ui + 1:][]
         | select(.type == "user")
         | select((.isMeta // false) != true)
         | select((.isSidechain // false) != true)
         | select((.isCompactSummary // false) != true)
         | select((.isVisibleInTranscriptOnly // false) != true)
         | select((.message.content | tostring | test("CALL_ID: " + $nonce)) | not)
         | (if (.message.content | type) == "string"
            then .message.content
            else ([.message.content[]? | select(.type == "text") | .text] | join(" "))
            end)
         | select(. != null)
         | gsub("^\\s+|\\s+$"; "")
         | select(length > 0)
       ] | first) as $p
      | if $p == null then {preempted: false, prompt: ""}
        else {preempted: true, prompt: ($p[0:200])}
        end
    end
' "$TRANSCRIPT") || { echo "jq failed parsing $TRANSCRIPT" >&2; exit 2; }

if [[ "$(printf '%s' "$PARSED" | jq -r '.preempted')" == "true" ]]; then
  printf '%s\n' "$(printf '%s' "$PARSED" | jq -r '.prompt')"
  exit 0
fi
exit 1
