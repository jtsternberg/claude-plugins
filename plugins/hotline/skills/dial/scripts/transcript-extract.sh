#!/usr/bin/env bash
# =============================================================================
# Transcript Extract: read a callee's Claude Code JSONL transcript and report,
# for one hotline call (identified by its CALL_ID nonce), whether the message
# submitted and — once the turn completes — the response body.
#
# This replaces terminal screen-scraping. The transcript is the structured
# source of truth: Claude Code flushes one JSON event per line in real time
# (verified live — a mid-turn session's file was <10s stale, ms-timestamped).
# We correlate on the nonce in event DATA, not on rendered pixels, so it's
# immune to REPL chrome (box glyphs, prompt markers, ANSI, spinners) that vary
# by claude version. (claude-plugins-0pwc)
#
# Schema facts this relies on (verified against real transcripts):
#   - `type:"user"` events carry the typed message in `.message.content`, which
#     is EITHER a string (slash-command / raw follow-up) OR an array of blocks
#     (tool results) — so we match the nonce against `.message.content|tostring`.
#   - `type:"assistant"` events carry `.message.content[]` blocks of type
#     `text` | `thinking` | `tool_use`; only `text` blocks are response prose.
#   - `.isSidechain == true` marks subagent turns — excluded so a spawned
#     agent's chatter never pollutes the response.
#   - `.sessionId` is on every event.
# The receiver still brackets its answer with the ringing protocol's
# `STATUS: WORK_IN_PROGRESS call_id=<nonce>` … `STATUS: <terminal> call_id=<nonce>`
# sentinels; we apply that same bracketing to the structured text.
#
# Exit codes (the contract wait-for-response.sh polls on):
#   0  — turn complete: prints {"session_id":"…","response":"…"} (compact JSON)
#   10 — submitted (a user event carries the nonce) but no terminal STATUS yet
#        → caller keeps waiting patiently (model is working)
#   11 — not submitted yet (no user event carries the nonce)
#        → caller fails fast once its submit-deadline passes
#   1  — usage / unreadable transcript error (message on stderr)
#
# Usage:
#   transcript-extract.sh <transcript.jsonl> <call_id-nonce>
# =============================================================================
set -euo pipefail

TRANSCRIPT="${1:-}"
NONCE="${2:-}"

[[ -z "$TRANSCRIPT" || -z "$NONCE" ]] && {
  echo "usage: transcript-extract.sh <transcript.jsonl> <call_id-nonce>" >&2
  exit 1
}
[[ -r "$TRANSCRIPT" ]] || { echo "transcript not readable: $TRANSCRIPT" >&2; exit 1; }

# One jq slurp pass: locate the first user event carrying the nonce, then gather
# every non-sidechain assistant TEXT block at or after it, in order, joined with
# newlines. Emits a small JSON object we finish parsing in bash.
#   .submitted  — did any user event carry the nonce?
#   .session_id — the nonce user event's session (fallback: last seen)
#   .text       — concatenated assistant prose after the nonce user event
PARSED=$(jq -s -c --arg nonce "$NONCE" '
  (map(.type == "user"
       and ((.message.content | tostring) | test("CALL_ID: " + $nonce)))
   | index(true)) as $ui
  | if $ui == null then
      {submitted: false, session_id: "", text: ""}
    else
      {submitted: true,
       session_id: (.[$ui].sessionId // (map(.sessionId // empty) | last) // ""),
       text: ([ .[$ui + 1:][]
                | select(.type == "assistant" and (.isSidechain != true))
                | .message.content[]?
                | select(.type == "text")
                | .text ]
              | join("\n"))}
    end
' "$TRANSCRIPT") || { echo "jq failed parsing $TRANSCRIPT" >&2; exit 1; }

SUBMITTED=$(printf '%s' "$PARSED" | jq -r '.submitted')
[[ "$SUBMITTED" != "true" ]] && exit 11

SESSION_ID=$(printf '%s' "$PARSED" | jq -r '.session_id')
TEXT=$(printf '%s' "$PARSED" | jq -r '.text')

# Terminal STATUS for THIS nonce present yet?
TERM_RE="STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE) call_id=${NONCE}[[:space:]]*$"
if ! printf '%s\n' "$TEXT" | grep -qE "$TERM_RE"; then
  exit 10   # submitted, still working
fi

# Extract the response body: reset the buffer at each WORK_IN_PROGRESS (so only
# the final attempt's prose counts — matches the screen-scrape semantics), stop
# at the terminal STATUS, drop the STATUS sentinel lines, and trim surrounding
# blank lines.
BODY=$(printf '%s\n' "$TEXT" | awk -v nonce="$NONCE" '
  BEGIN {
    wip  = "STATUS: WORK_IN_PROGRESS call_id=" nonce "[[:space:]]*$"
    term = "STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE) call_id=" nonce "[[:space:]]*$"
  }
  $0 ~ wip  { n=0; delete L; next }
  $0 ~ term { stop=1; exit }
  { L[++n] = $0 }
  END {
    # trim leading blanks
    s=1; while (s<=n && L[s] ~ /^[[:space:]]*$/) s++
    e=n; while (e>=s && L[e] ~ /^[[:space:]]*$/) e--
    for (i=s; i<=e; i++) print L[i]
  }
')

jq -n -c --arg sid "$SESSION_ID" --arg resp "$BODY" '{session_id: $sid, response: $resp}'
exit 0
