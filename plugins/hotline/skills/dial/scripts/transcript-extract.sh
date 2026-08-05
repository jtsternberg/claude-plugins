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
#   - A message typed into a REPL that is mid-turn is QUEUED, and claude records
#     that as `type:"queue-operation"` (`operation:"enqueue"`, text in
#     `.content`). See the two delivery paths below.
# The receiver still brackets its answer with the ringing protocol's
# `STATUS: WORK_IN_PROGRESS call_id=<nonce>` … `STATUS: <terminal> call_id=<nonce>`
# sentinels; we apply that same bracketing to the structured text.
#
# Exit codes (the contract wait-for-response.sh polls on):
#   0  — turn complete: prints {"session_id":"…","response":"…"} (compact JSON)
#   10 — submitted (see SUBMIT EVIDENCE) but no terminal STATUS yet
#        → caller keeps waiting patiently (model is working)
#   11 — no submit evidence for the nonce anywhere in the transcript
#        → caller consults the callee's input box before concluding anything
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
# SUBMIT EVIDENCE — WHY A `user` RECORD IS NOT THE ONLY PROOF (claude-plugins-1jpz)
# A message typed into a REPL that is already mid-turn does NOT produce a user
# record at submit time. It is enqueued, and claude then delivers it one of two
# ways (both observed live on 2.1.221):
#   (a) TOOL-BOUNDARY INJECTION — if the busy turn hits another tool call, the
#       queued text is handed to the model INSIDE that same turn as
#       `type:"attachment"` with `.attachment.type == "queued_command"` and the
#       text in `.attachment.prompt` (parentUuid = the tool_result). NO
#       `type:"user"` record is EVER written for it, yet the model reads and
#       answers it — measured 8ms after the boundary.
#   (b) TURN-END FLUSH — if the turn makes no further tool call, the queue drains
#       after it ends as a genuine `type:"user"` record (+5.5s measured).
# Correlating on user records alone therefore reported "never submitted" for
# path (a) messages the receiver had already ANSWERED. So four things count as
# proof, in this precedence order (the winner also anchors where the response
# body starts, so prose from the swallowed prior task cannot leak in):
#   1. a `user` record carrying the nonce            (paths: idle send, and (b))
#   2. a `queued_command` attachment carrying it     (path (a) delivery)
#   3. the receiver's own `STATUS: … call_id=<nonce>` — an answer in hand is
#      proof of receipt no matter which records are missing
#   4. the `enqueue` record — written the instant the REPL accepts the
#      keystrokes, so it proves submit before either path resolves
# 3 is deliberately ranked above 4: it is the later, tighter anchor. The enqueue
# lands mid-prior-turn, so anchoring there would splice that turn's tail onto our
# response body.
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

# One jq slurp pass: locate the record that proves our message reached the
# callee (see SUBMIT EVIDENCE in the header), then gather every non-sidechain
# assistant TEXT block from there on, in order, joined with newlines. Emits a
# small JSON object we finish parsing in bash.
#   .submitted  — does ANY submit evidence carry the nonce?
#   .session_id — the anchor record's session (fallback: last seen)
#   .text       — concatenated assistant prose from the anchor record onward
PARSED=$(jq -s -c --arg nonce "$NONCE" '
  ("CALL_ID: " + $nonce) as $tag
  | ("call_id=" + $nonce) as $stag
  # (1) a genuine user record carrying the nonce — an idle-REPL send, or a
  #     queued follow-up flushed after the busy turn ended (delivery path (b)).
  | (map(.type == "user"
         and ((.message.content | tostring) | test($tag)))
     | index(true)) as $ui
  # (2) a queued follow-up injected into the busy turn at a tool boundary
  #     (delivery path (a)). No user record accompanies this one, ever.
  | (map(.type == "attachment"
         and ((.isSidechain // false) != true)
         and (((.attachment // {}) | if type == "object" then . else {} end)
              | (.type == "queued_command")
                and (((.prompt // "") | tostring) | test($tag))))
     | index(true)) as $qi
  # (3) the receiver naming our call_id in its own STATUS line. An answer in hand
  #     outranks any missing bookkeeping record.
  | (map(.type == "assistant"
         and ((.isSidechain // false) != true)
         and (([.message.content[]? | select(.type == "text") | .text] | join("\n"))
              | test("STATUS: [A-Z_]+ " + $stag)))
     | index(true)) as $ai
  # (4) the enqueue record — the REPL accepted the keystrokes, delivery pending.
  | (map(.type == "queue-operation"
         and (.operation == "enqueue")
         and (((.content // "") | tostring) | test($tag)))
     | index(true)) as $ei
  | ([$ui, $qi] | map(select(. != null)) | min) as $di
  | ($di // $ai // $ei) as $ui
  | if $ui == null then
      {submitted: false, session_id: "", text: "", preempt: ""}
    else
      {submitted: true,
       session_id: (.[$ui].sessionId // (map(.sessionId // empty) | last) // ""),
       # From the anchor INCLUSIVE: when the anchor is the receivers own STATUS
       # record (evidence 3) the answer lives in that record. Anchors of the
       # other three kinds are not assistant records, so including them is a
       # no-op here.
       text: ([ .[$ui:][]
                | select(.type == "assistant" and (.isSidechain != true))
                | .message.content[]?
                | select(.type == "text")
                | .text ]
              | join("\n")),
       # First genuine human prompt after our turn, if any — see the preemption
       # note in the header. tool_result records contribute no text blocks, so
       # they drop out here without a special case. Our own anchor record is
       # excluded by the nonce test below.
       preempt: ([ .[$ui:][]
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
