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
#   12 — PREEMPTED: no terminal STATUS, and a genuine human prompt arrived after
#        our turn, so it is never coming. The preempting prompt (200 chars) goes
#        to stdout. → caller stops waiting instead of sitting out its timeout.
#   1  — usage / unreadable transcript error (message on stderr)
#
# PREEMPTION (claude-plugins-dvjo)
# A cmux call lands in a VISIBLE surface, and a visible surface is one the human
# can type into — that is the point of side-by-side placement, not a misuse. Once
# they give that session another task, our STATUS never arrives; waiting out the
# remaining 1800s tells the caller nothing. Counted as preemption: a new human
# prompt (including one typed as a slash command) and `[Request interrupted by
# user…]`. NOT counted: tool_result records (no text blocks), isMeta /
# isSidechain / isCompactSummary / isVisibleInTranscriptOnly records, our own
# nonce turn or a replay of it, and anything BEFORE our nonce turn. Client-side
# commands (/model, /clear) are type:"system" subtype:"local_command" rather than
# user records, so they are out of scope for free — right for /model, a known miss
# for /clear, which the timeout still catches.
#
# WHY THIS STAYS jq AND SELF-CONTAINED (claude-plugins-wn09)
# The obvious-looking cleanup is to retire this in favour of session-tools'
# lib/transcript.mjs. Measured, that is wrong twice over. transcript.mjs applies
# stripSystemNoise to ASSISTANT prose, so a reply that legitimately quotes a
# harness block — "the bug is that <system-reminder>…</system-reminder> leaks into
# the dashboard", an actual hotline answer — comes back with the quote deleted:
# "the bug is that  leaks into the dashboard". Corrupting response bodies to
# de-duplicate a parser is a bad trade. And none of the logic that matters here
# (nonce correlation, STATUS bracketing, WORK_IN_PROGRESS reset) exists in
# transcript.mjs, so the protocol code would stay in hotline anyway while the
# plugin gained a hard dependency on session-tools and stopped installing
# standalone. This file is not a vendored copy of that parser; it is hotline's own
# protocol reader, and it is deliberately noise-preserving.
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
      {submitted: false, session_id: "", text: "", preempt: ""}
    else
      {submitted: true,
       session_id: (.[$ui].sessionId // (map(.sessionId // empty) | last) // ""),
       text: ([ .[$ui + 1:][]
                | select(.type == "assistant" and (.isSidechain != true))
                | .message.content[]?
                | select(.type == "text")
                | .text ]
              | join("\n")),
       # First genuine human prompt after our turn, if any — see the preemption
       # note in the header. tool_result records contribute no text blocks, so
       # they drop out here without a special case.
       preempt: ([ .[$ui + 1:][]
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
                 ] | first // "")}
    end
' "$TRANSCRIPT") || { echo "jq failed parsing $TRANSCRIPT" >&2; exit 1; }

SUBMITTED=$(printf '%s' "$PARSED" | jq -r '.submitted')
[[ "$SUBMITTED" != "true" ]] && exit 11

SESSION_ID=$(printf '%s' "$PARSED" | jq -r '.session_id')
TEXT=$(printf '%s' "$PARSED" | jq -r '.text')
PREEMPT=$(printf '%s' "$PARSED" | jq -r '.preempt')

# Terminal STATUS for THIS nonce present yet?
#
# Checked BEFORE preemption on purpose: a receiver that answered our call and was
# THEN handed something else has still answered, and that response is owed to the
# caller. Preemption only decides what to do when no terminal STATUS exists.
TERM_RE="STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE) call_id=${NONCE}[[:space:]]*$"
if ! printf '%s\n' "$TEXT" | grep -qE "$TERM_RE"; then
  if [[ -n "$PREEMPT" ]]; then
    printf '%s\n' "${PREEMPT:0:200}"
    exit 12   # reassigned — our STATUS is never coming
  fi
  exit 10     # submitted, still working
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
