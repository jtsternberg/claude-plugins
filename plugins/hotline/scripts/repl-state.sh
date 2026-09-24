#!/usr/bin/env bash
# =============================================================================
# REPL state: reading a live claude REPL's condition, and resolving the cmux
# address of the surface it lives in.
#
# SOURCE this, don't execute it. Several scripts need the same judgements and
# must never disagree about them:
#
#   skills/dial/scripts/cmux-paste.sh               — is this REPL ready for a
#                                                     payload, and where is it?
#   skills/dial/scripts/cmux-reuse-surface.sh       — may I speak to this REPL?
#   skills/dial/scripts/close-superseded-surface.sh — is this REPL safe to kill?
#
# The last question is strictly more dangerous than the others, and all of them
# turn on the same signals. Duplicating them is how one copy learns about a new
# spinner wording and the other doesn't — this repo has lost time to exactly that
# in the transcript parser, twice.
#
# The screen-reading PREDICATES take a captured screen as $1 and read nothing
# themselves. The CAPTURE, though, is not the caller's choice: a plain
# `cmux read-screen` follows the user's scroll, so all of it goes through
# cmux_read_live below. cmux_surface_address and input_box_is_placeholder are the
# other two functions here that talk to cmux — the latter because the question it
# answers (placeholder or unsent input?) is not present in a plain-text screen at
# all.
# =============================================================================

# --- Addressing a cmux surface: never let cmux choose one for us ---------------
# cmux substitutes a target for a missing or unparseable one instead of refusing
# the call, and WHICH one it substitutes depends on the path. Both readings are
# live, and they point at different surfaces:
#
#   A CLI verb falls back to the inherited `$CMUX_*_ID` env vars, so
#   `cmux send --surface ""` lands on THE CALLER'S OWN surface. Four incidents:
#   three typed probe text into a bystander's live REPL (2026-08-26), one into
#   the operator's own input box mid-conversation (2026-09-21, confirmed by a
#   `surface.input_sent` frame whose `result.surface_id` was the caller's).
#
#   A malformed `cmux rpc` — camelCase param keys, silently dropped — resolves
#   against the FOCUSED surface and returns ok:true carrying its grid
#   (claude-plugins-r465.9).
#
# So an empty handle never means "no target". Which wrong surface it means decides
# where to look when one slips through, and for the CLI verbs every dial script
# uses, the answer is "check your own pane first" — not the user's focused one.
#
# cmux_handle_ok <what> <handle> — 0 when the handle is safe to address.
cmux_handle_ok() {
  [[ -n "${2:-}" ]] && return 0
  printf 'hotline: refusing a cmux call for %s — its target handle is empty, and a cmux CLI verb falls back to the inherited $CMUX_*_ID rather than failing, delivering to THIS pane (claude-plugins-r465.9, -99nu).\n' \
    "${1:-<unnamed call>}" >&2
  return 1
}

# --- cmux events: facts about what cmux did, not inferences from a TUI --------
# `cmux events` (cmux >= 0.64.25) streams retained NDJSON for surfaces opening,
# prompts submitting, and agent turns starting and ending. Every question the
# screen-reading predicates below ANSWER BY INFERENCE, this answers by
# measurement — so reach for these first and treat the screen reads as the
# documented fallback for a cmux that predates the stream, or for no cmux at all.
# The catalog, payload shapes and traps live in
# plugins/cmux-cli/skills/using-cmux-cli/references/events.md; that file is the
# verified contract and this section is its binding, not a second source.
#
# Five traps are handled here so no caller has to remember them:
#
#   1. The ack frame goes to STDOUT and carries no `.name`, and the timeout
#      message goes to STDERR. Both break a naive jq filter, so every frame READ
#      is `--no-ack --no-heartbeat 2>/dev/null`. THE EXCEPTION IS `--snapshot`,
#      which prints the ack and exits — there the ack is the payload, and adding
#      `--no-ack` suppresses the only line it emits and returns nothing at all.
#   2. `--limit` counts FRAMES, not matches. When a jq filter does the narrowing,
#      bound the wait with `--timeout` and stop at the first match instead.
#   2b. The `--name` narrowing is cmux's, server-side. The query builders below
#      ALSO check `.name` client-side, so a filter can never be satisfied by a
#      frame of some other name — which is what makes these waiters testable
#      against a stub that does not reimplement cmux's filtering, and what keeps
#      a future `--name` regression from turning a turn-end wait into a
#      session-start match.
#   3. Stopping reading does NOT stop cmux. It holds the stream open for its
#      whole --timeout, so a naive `| head -1` costs the full window however
#      early the frame arrived — measured, and the reason cmux_events_first
#      kills the producer itself rather than closing a pipe at it.
#   4. `agent.hook.*` fires TWICE per occurrence — `payload.phase` is "received"
#      then "completed". Undeduplicated, every turn counts double.
#   5. A frame's top-level `surface_id` can be null on some `agent.hook.*` frames,
#      where a `select(.surface_id == $s)` filter drops them silently. The waiters
#      that can fall back to `payload.cwd` / `payload.workspace_id` do.
#
# The retained buffer is a ROLLING WINDOW. A name's absence from a replay means
# "nothing did that recently", never "this event does not exist" — so an empty
# result is never evidence that a capability is missing.

# cmux_events_supported — 0 when this cmux can answer event queries.
# Probed once per process via --snapshot (which prints the ack and exits), then
# cached: the screen-reading fallbacks exist for the "no" answer, and a
# per-call probe would tax every one of them. HOTLINE_CMUX_EVENTS=0|1 forces the
# answer, which is how the suites drive both paths without a real cmux.
HOTLINE_CMUX_EVENTS_CACHE=""
cmux_events_supported() {
  if [[ -n "${HOTLINE_CMUX_EVENTS:-}" ]]; then
    [[ "$HOTLINE_CMUX_EVENTS" == "1" ]] && return 0
    return 1
  fi
  [[ -n "$HOTLINE_CMUX_EVENTS_CACHE" ]] && return "$HOTLINE_CMUX_EVENTS_CACHE"
  # Probe by PARSING a seq, not by exit code. `cmux events --snapshot` exits 0
  # even when its output is suppressed or unreadable, so an exit-code probe
  # reports a usable stream for a cmux whose frames we cannot read — and then
  # every waiter arms against a marker it never got.
  local probe
  probe=$(cmux events --snapshot --no-heartbeat 2>/dev/null \
          | jq -r '.resume.latest_seq // empty' 2>/dev/null) || true
  if [[ -n "$probe" && "$probe" != "null" ]]; then
    HOTLINE_CMUX_EVENTS_CACHE=0
  else
    HOTLINE_CMUX_EVENTS_CACHE=1
  fi
  return "$HOTLINE_CMUX_EVENTS_CACHE"
}

# cmux_events_seq — the latest retained seq, as a BEFORE marker.
# Capture this before a send, then pass it as --after so the query sees only
# frames caused by that send. Empty on any failure; a caller that got nothing
# must not fall back to --after 0, which would replay unrelated history.
cmux_events_seq() {
  cmux_events_supported || return 1
  local seq
  # NO --no-ack HERE. `--snapshot` prints the subscription ack and exits, so the
  # ack IS the payload — `--snapshot --no-ack` suppresses the only line it emits
  # and yields nothing, silently. The "scripted use is always --no-ack" rule
  # applies to frame READS, where the ack is noise; this is the exception.
  seq=$(cmux events --snapshot --no-heartbeat 2>/dev/null \
        | jq -r '.resume.latest_seq // empty' 2>/dev/null) || true
  [[ -n "$seq" && "$seq" != "null" ]] || return 1
  printf '%s' "$seq"
}

# cmux_events_first <timeout> <jq-filter> <name>... — first matching frame.
# Prints the frame as compact JSON and returns 0, or returns 1 on no match.
# $HOTLINE_EVENTS_AFTER, when set, scopes the query to frames after that seq.
#
# RETURNS AS SOON AS THE FRAME ARRIVES, which took three tries to actually get:
#
#   `cmux events … | jq … | head -1` does NOT return early. `head` exiting only
#   SIGPIPEs jq on jq's NEXT write, and jq has nothing more to write — so jq
#   drains the rest of the window and the wait costs the full --timeout no
#   matter when the frame landed. A 600s turn-end wait would sit 600s on a Stop
#   that arrived in 2s, making every migrated waiter SLOWER than the read-screen
#   poll it replaced. Measured: 6s of a 6s window for a frame delivered at 0s.
#
#   `jq -n 'first(inputs|…)'` does exit on the first match, but a command
#   substitution waits for every process in the pipeline, and cmux holds the
#   stream open for its whole window without writing (we pass --no-heartbeat),
#   so it never notices the closed pipe. Also 6s.
#
# So the reader has to terminate the producer itself: cmux writes into a FIFO in
# the background, `jq -n first(...)` exits on the match, and we kill cmux. The
# kill is not tidiness — process substitution measured the same 0s but left a
# `cmux events --timeout 600` orphan per wait, and orphaned stream readers are a
# leak this transport already guards against elsewhere.
cmux_events_first() {
  cmux_events_supported || return 1
  local timeout="$1" filter="$2"; shift 2
  local -a names=()
  local n; for n in "$@"; do names+=(--name "$n"); done
  local -a after=()
  [[ -n "${HOTLINE_EVENTS_AFTER:-}" ]] && after=(--after "$HOTLINE_EVENTS_AFTER")
  local nameset
  nameset=$(printf '%s\n' "$@" | jq -R . | jq -sc .)

  # macOS hands out a TMPDIR with a trailing slash, which mktemp templates into a
  # double-slashed path; the suites normalize for the same reason.
  local tmproot="${TMPDIR:-/tmp}"; tmproot="${tmproot%/}"
  local fifo
  fifo=$(mktemp -u "$tmproot/hotline-events.XXXXXX") || return 1
  mkfifo "$fifo" 2>/dev/null || return 1

  cmux events "${names[@]}" "${after[@]}" \
              --timeout "$timeout" --no-ack --no-heartbeat >"$fifo" 2>/dev/null &
  local cpid=$!

  local out
  out=$(jq -c -n --argjson want "$nameset" \
          "first(inputs | select((.name // \"\") as \$n | \$want | index(\$n)) | $filter)" \
          <"$fifo" 2>/dev/null) || true

  kill "$cpid" 2>/dev/null || true
  wait "$cpid" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true

  [[ -n "$out" && "$out" != "null" ]] || return 1
  printf '%s' "$out"
}

# cmux_events_all <timeout> <limit> <jq-filter> <name>... — every match in window.
# For the questions where the COUNT is the answer: two
# `workspace.prompt.submitted` frames for one send is fragmentation, not a
# clean submit. One frame per line on stdout; returns 1 when there were none.
#
# UNLIKE cmux_events_first, THIS ALWAYS COSTS THE FULL <timeout>. It cannot
# return early — "were there more frames after the first?" is only answerable by
# waiting. So the timeout is a settle window to be budgeted, not an upper bound
# that a fast answer escapes. Callers that need a fast yes and a slower
# how-many should ask cmux_events_first for the yes and come back here for the
# count.
cmux_events_all() {
  cmux_events_supported || return 1
  local timeout="$1" limit="$2" filter="$3"; shift 3
  local -a names=()
  local n; for n in "$@"; do names+=(--name "$n"); done
  local -a after=()
  [[ -n "${HOTLINE_EVENTS_AFTER:-}" ]] && after=(--after "$HOTLINE_EVENTS_AFTER")
  local nameset
  nameset=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  local out
  out=$(
    cmux events "${names[@]}" "${after[@]}" --limit "$limit" \
                --timeout "$timeout" --no-ack --no-heartbeat 2>/dev/null \
      | jq -c --argjson want "$nameset" \
          "select((.name // \"\") as \$n | \$want | index(\$n)) | $filter" 2>/dev/null
  ) || true
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# --- Purpose-built waiters ----------------------------------------------------

# cmux_wait_surface_created <pane_id> <timeout> — the surface EXISTS.
# It does NOT mean the PTY is attached: a `cmux send` is what attaches it, so the
# readiness probe in surface-ready.sh still has to run after this returns.
cmux_wait_surface_created() {
  local pane="$1" timeout="${2:-30}"
  cmux_events_first "$timeout" \
    "select(.pane_id == \"$pane\")" surface.created
}

# cmux_wait_session_start <cwd> <timeout> [expect_session_id]
#   — prints the callee's BARE claude session uuid once its REPL has booted.
#
# Matches on payload.cwd because this signal can arrive before we know which
# surface the session landed in.
#
# PASS THE EXPECTED SESSION ID WHENEVER ONE IS KNOWN. A cwd is not unique to a
# call: the operator's own claude session running in the same directory emits an
# identical-looking SessionStart, and a cwd-only match would promote a boot that
# is not ours. Callers that launched with a preset `--session-id` know exactly
# which id to expect, so the match becomes exact — and the frame then CONFIRMS
# the preset instead of the caller having to assume claude honoured it.
#
# `payload.session_id` IS NOT A BARE UUID. cmux reports a composite feed id,
#   cmux-feed-v1:<base64 of the agent name>:<base64 of the session uuid>
# e.g. `cmux-feed-v1:Y2xhdWRl:ZDFkNzIyYjkt…` for claude session
# d1d722b9-d8c1-42ef-987e-468ce2662c73 (measured live on cmux 0.64.25). Two
# consequences, both of which made this function useless before they were fixed:
# an equality test against a bare preset can never match, and RETURNING the
# frame's value would hand the caller a composite where every consumer —
# session_id.txt, transcript paths, the call registry — needs the uuid. A uuid
# is 36 bytes, so its base64 is padding-free and a substring test is exact.
cmux_wait_session_start() {
  local cwd="$1" timeout="${2:-120}" expect="${3:-}"
  local idsel=""
  if [[ -n "$expect" ]]; then
    local expect_b64
    expect_b64=$(printf '%s' "$expect" | base64 | tr -d '\n')
    # Accept either spelling: the composite cmux reports today, or a bare uuid,
    # so a build that stops wrapping it does not silently kill this signal.
    idsel=" and ((.payload.session_id // \"\") | (. == \"$expect\" or contains(\"$expect_b64\")))"
  fi
  local frame
  frame=$(cmux_events_first "$timeout" \
    "select(.payload.phase == \"completed\" and (.payload.cwd // \"\") == \"$cwd\"$idsel)" \
    agent.hook.SessionStart) || return 1

  # Matched on a preset: return the preset. It is the bare uuid by construction,
  # and the frame's own value is the composite.
  if [[ -n "$expect" ]]; then
    printf '%s' "$expect"
    return 0
  fi

  local sid
  sid=$(printf '%s' "$frame" | jq -r '.payload.session_id // empty' 2>/dev/null) || true
  [[ -n "$sid" && "$sid" != "null" ]] || return 1
  case "$sid" in
    cmux-feed-v1:*) sid=$(printf '%s' "${sid##*:}" | base64 -d 2>/dev/null) || return 1 ;;
  esac
  [[ -n "$sid" ]] || return 1
  printf '%s' "$sid"
}

# cmux_wait_turn_end <surface_id> <timeout> — the callee's turn is over.
# Replaces a poll cadence with one blocking call that burns no model tokens.
# SubagentStop and SessionEnd are matched alongside Stop: a callee that exits
# instead of settling is still a turn that ended, and waiting for a Stop that
# will never come is how a poller hangs to its deadline.
#
# THE SURFACE MATCH IS WEAK, DELIBERATELY. `agent.hook.Stop` carries a null
# `surface_id` on a large share of real frames, so the null fallback below is
# what makes it match at all — and that same fallback means ANY session's turn
# end satisfies this call. Fine for "something finished"; NOT sufficient for
# "the callee I dialed finished". A caller that must attribute the turn should
# discriminate on `payload.cwd` or `payload.session_id` (a composite — see
# cmux_wait_session_start), both of which real frames do carry.
cmux_wait_turn_end() {
  local surf="$1" timeout="${2:-600}"
  cmux_events_first "$timeout" \
    "select(.payload.phase == \"completed\" and ((.surface_id // \"\") == \"$surf\" or .surface_id == null))" \
    agent.hook.Stop agent.hook.SubagentStop agent.hook.SessionEnd
}

# cmux_wait_session_turn_end <session_uuid> <timeout> — THE CALLEE I DIALED
# finished its turn. The attributable form of cmux_wait_turn_end, and the only one
# a response waiter may gate on.
#
# WHY NOT cmux_wait_turn_end: its surface match falls back to a null surface_id,
# because most real Stop frames carry one (measured on 0.64.25: 18 of 42 with a
# null top-level surface_id, and payload.surface_id null on exactly the same 18).
# That fallback is what makes it match at all, and it also makes ANY session's turn
# end satisfy it — a caller waiting on its callee would wake on the operator
# finishing a turn in another pane.
#
# WHY NOT payload.cwd EITHER, which is the other field every frame carries. Two
# measurements kill it:
#   • A cwd is not one session. In a single 900-frame replay, /Users/JT/Code/
#     claude-plugins carried agent.hook frames for two different session ids, and
#     so did a second directory — and a hotline callee runs in the CALLER'S OWN
#     cwd by definition, so that collision is the common case, not an edge one.
#   • A cwd is not even one value per session. The same session emitted frames
#     under both its launch directory and a subdirectory it had cd'd into, so an
#     equality test against the launch cwd misses frames the callee really sent.
# The first failure wakes a waiter on somebody else's turn; the second blocks it
# through a turn end that did happen. Only the session id is sound.
#
# payload.session_id IS A COMPOSITE — cmux-feed-v1:<base64 agent>:<base64 uuid> —
# so an equality test against a bare uuid never matches. Both spellings are
# accepted, exactly as in cmux_wait_session_start, so a build that stops wrapping
# the id does not silently turn this into a wait that never returns.
#
# SubagentStop and SessionEnd are matched alongside Stop for the same reason the
# weak waiter matches them: a callee that exits instead of settling is still a turn
# that ended, and waiting for a Stop that will never come is how a poller hangs to
# its deadline.
cmux_wait_session_turn_end() {
  local sess="$1" timeout="${2:-600}"
  [[ -n "$sess" ]] || return 2
  local sess_b64
  sess_b64=$(printf '%s' "$sess" | base64 | tr -d '\n')
  cmux_events_first "$timeout" \
    "select(.payload.phase == \"completed\" and ((.payload.session_id // \"\") | (. == \"$sess\" or contains(\"$sess_b64\"))))" \
    agent.hook.Stop agent.hook.SubagentStop agent.hook.SessionEnd
}

# cmux_submit_lengths <workspace_id> <settle_seconds> — one message_length per line.
# The settle window is spent in full on every call (see cmux_events_all), so the
# default is small: distinguishing a clean submit from a fragmented one is the
# only thing the extra wait buys, and the paste path confirms in well under a
# second today. Do not raise it to a read-timeout-sized number.
#
# `message_length` IS CAPPED AT 240 — it is the length of the 240-char
# `message_preview`, not of the message (events.md has the measurement: 21/21
# submissions with message_length == preview length, 14 at exactly 240, none
# above). So read a value as three-valued, never as an equality:
# tripwire: claude-plugins-8ur4 — cmux#13687; if that is fixed, this cap and the
# at-least-240 reading go away, and a real length check becomes worth having.
#   no lines        → nothing submitted; the text sits in the box and `send-key
#                     Enter` is the fix (never a re-send, which appends).
#   one line < 240  → exact; a value under what was sent is byte loss at the
#                     transport.
#   one line == 240 → "240 or more", and nothing more. Every real hotline work
#                     order is longer than that, so a whole payload and a
#                     truncated one report the same number — this field CANNOT
#                     verify one. Use the nonce (a grep -F of the call id in the
#                     callee's transcript), which is byte-definitive.
#   several lines   → fragmentation; the payload arrived as multiple turns.
# Do NOT length-check against agent.hook.UserPromptSubmit instead: its
# tool_input_length counts claude's own wrapping (56 where this reported 43).
#
# NOR IS THE COUNT HERE ATTRIBUTABLE TO ONE REPL. `workspace.prompt.submitted`
# carries no surface_id and no session_id (measured: 16/16 frames with a null
# top-level surface_id and no such payload key), so this is workspace-scoped —
# and a side-by-side hotline call puts the caller's REPL and the callee's in ONE
# workspace (measured: one workspace_id hosting two session_ids on two
# surface_ids). Counting turns for a specific callee is cmux_prompt_ingests.
#
# AND A DETACHED CALLEE HIDES THAT. Detached placement gives the callee its own
# workspace, so this count and cmux_prompt_ingests agree there — measured on two
# real dials, 1/1 detached against 1/2 side. A smoke that only ever dials detached
# will bless this primitive for a job it cannot do on the default placement.
cmux_submit_lengths() {
  local ws="$1" timeout="${2:-2}"
  cmux_events_all "$timeout" 10 \
    "select(.workspace_id == \"$ws\") | .payload.message_length" \
    workspace.prompt.submitted
}

# cmux_prompt_ingests <surface_id> <session_uuid|""> <settle_seconds>
#   — one seq per prompt THIS callee's REPL ingested in the window.
#
# The count is the answer: two ingests for one delivery means the payload
# arrived as several turns, which the paste path's confirmation ladder reports as
# a clean delivery (it proves the nonce landed, not how many turns it landed as).
#
# `agent.hook.UserPromptSubmit` AND NOT `workspace.prompt.submitted`, even though
# the latter is the REPL-accept signal, because the latter cannot say WHOSE
# submit it was: it carries no surface_id and no session_id, and a side-by-side
# call shares one workspace between caller and callee (see cmux_submit_lengths).
# A workspace-scoped count would report fragmentation for a clean delivery
# whenever the operator typed into their own pane inside the settle window.
# UserPromptSubmit carries surface_id, session_id and cwd on every frame
# (measured: 21/21, both phases), so the attribution is exact. The
# tool_input_length warning on that event is about its LENGTH, which this does
# not read.
#
# THE COUNT IS A FLOOR, NOT A TALLY, and two separate mechanisms make it one:
#   • It fires when claude INGESTS the prompt, not when the box accepts it, so a
#     paste QUEUED behind a live turn is counted when the queue flushes — possibly
#     after this window closes.
#   • A `--after <seq> --limit <n>` replay does not reach the newest frames
#     (events.md, "A replay window does not reach the newest frames"), so a frame
#     landing between the caller's marker and this query can fall in that gap. The
#     live half of the window still delivers anything that arrives while it is
#     open, which is where a paste's own frames normally come from.
# Both err the same way — a caller sees fewer turns than happened, never more — so
# a count above 1 is real fragmentation and a count of 1 is not proof of a clean
# single turn. Read it as "at least this many".
#
# Case-insensitive on the surface id: the handle a caller holds comes from the
# cmux tree and the frame's comes from the hook bridge, and a UUID that differs
# only in case would silently match nothing.
cmux_prompt_ingests() {
  local surf="$1" sess="${2:-}" timeout="${3:-2}"
  local surf_lc
  surf_lc=$(printf '%s' "$surf" | tr 'A-Z' 'a-z')
  local sesssel=""
  if [[ -n "$sess" ]]; then
    local sess_b64
    sess_b64=$(printf '%s' "$sess" | base64 | tr -d '\n')
    # The composite cmux reports today (cmux-feed-v1:<b64 agent>:<b64 uuid>), or a
    # bare uuid — see cmux_wait_session_start for why both spellings are accepted.
    sesssel=" and ((.payload.session_id // \"\") | (. == \"$sess\" or contains(\"$sess_b64\")))"
  fi
  # --limit counts frames, but --name has already narrowed them server-side, so 20
  # is 20 prompt submissions inside the settle window — far more than any
  # fragmentation this is looking for.
  cmux_events_all "$timeout" 20 \
    "select(.payload.phase == \"completed\" and (((.payload.surface_id // .surface_id) // \"\") | ascii_downcase) == \"$surf_lc\"$sesssel) | .seq" \
    agent.hook.UserPromptSubmit
}

# cmux_last_send_target <timeout> — the surface the most recent send RESOLVED to.
# The diagnostic counterpart to cmux_send_landed_on: that one answers "did it go
# where I meant", this one answers "then where did it go", which is the sentence
# an opaque timeout is missing. The ledger's entry on echoed targets asks for
# exactly this field, because a wrong answer arrives as a successful one.
cmux_last_send_target() {
  local timeout="${1:-3}"
  local frame
  frame=$(cmux_events_first "$timeout" "select(.payload.result.surface_id != null)" \
            surface.input_sent surface.key_sent) || return 1
  local sid
  sid=$(printf '%s' "$frame" | jq -r '.payload.result.surface_id // empty' 2>/dev/null) || true
  [[ -n "$sid" && "$sid" != "null" ]] || return 1
  printf '%s' "$sid"
}

# cmux_send_landed_on <intended_surface_id> <timeout> — 0 iff the last send
# resolved to the surface we meant. This is the mechanical form of the
# substituted-target check cmux_handle_ok can only refuse in advance: a handle
# that fails to resolve does not error, it silently retargets, and
# result.surface_id is the only place that shows up.
cmux_send_landed_on() {
  local want="$1" timeout="${2:-5}"
  cmux_events_first "$timeout" \
    "select(.payload.result.surface_id == \"$want\")" \
    surface.input_sent surface.key_sent >/dev/null
}

# --- Scroll-immune screen reads ----------------------------------------------
# A plain `cmux read-screen` returns what the surface is CURRENTLY SHOWING, so a
# user who has scrolled the pane up hands us a frozen capture — and "the screen
# did not change" then reads as "the REPL is idle", which is how a destructive
# cleanup could close a surface mid-turn. `--scrollback --lines N` returns the
# live tail regardless of scroll position (verified on cmux 0.64.22 against a
# pane scrolled to ~line 225, where the plain form returned the stale viewport),
# so every read in the dial transport takes that form.
#
# Do NOT reach for the render grid's `scrolled_rows` to detect scroll instead: it
# is forced to 0 whenever the reply is `full:true`, and every reply is
# (MobileTerminalRenderGrid.swift:212). It is structurally always 0.
#
# TWO WIDTHS, because two different questions get asked of a capture. IDENTITY
# questions (is our nonce in here?) want history. STATE questions (is the input
# box drawn? is a turn in flight?) want the LIVE SCREEN only — a 400-line
# scrollback still holds `(12s ·` elapsed parentheticals and `❯` echoes from
# turns that ended long ago, and matching those reports a busy REPL that is
# actually idle, which bounces every follow-up to a fresh surface.
HOTLINE_READ_LINES="${HOTLINE_READ_LINES:-400}"
#
# THE TAIL IS THE PANE'S OWN HEIGHT WHERE IT CAN BE MEASURED (cmux_screen_rows
# below), and 60 rows where it cannot. 60 is a stand-in for "about one pane
# height" — live panes measured on this machine ranged 13 to 83 occupied rows, so
# it is simultaneously too wide on a short pane and too narrow on a tall one.
# Wider is the unsafe direction — a previous claude session in the same surface
# leaves NBSP-padded box renders in the history, and repl_box_present matching one
# reports a live REPL where a shell is now running, which is how a work order gets
# pasted at a shell and RUN line by line. Narrower only drops rows that are
# genuinely on screen, which costs screen-side confirmation sensitivity and fails
# safe (undelivered/sent:true, never a false success).
#
# Set the env var and the measurement is skipped entirely: an explicit width is an
# operator's decision, and silently overriding it would make the knob a lie.
HOTLINE_SCREEN_TAIL_EXPLICIT="${HOTLINE_SCREEN_TAIL_LINES:+1}"
HOTLINE_SCREEN_TAIL_LINES="${HOTLINE_SCREEN_TAIL_LINES:-60}"
#
# AND ONE TIGHTER WINDOW FOR THE BOX GATES, because "about one pane height" is not
# tight enough for the one predicate whose false positive is destructive.
# repl_box_present matches ANYWHERE in the window it is handed, and panes are not
# all one size (measured on this machine: 13, 62, 71, 82, 83 occupied rows), so on
# any pane shorter than the tail the rest of that window is HISTORY. A previous claude
# session in the same surface leaves its NBSP-padded box render there, and matching
# that reports a live REPL where a shell is now running — `terminal.paste` with
# submit_key:"return" then types the whole work order at that shell and the shell
# RUNS it.
#
# 12 rows is what the box actually needs: claude draws its box at the bottom, with
# only a rule and one or two hint lines under it (a live capture of an idle REPL put
# the box 4 rows from the end). The boot wait has used this width since the fast-fail
# went in; the reuse and delivery box gates take the same one so the three places
# that ask "is a REPL drawn here?" cannot disagree about how far back to believe it.
# close-superseded-surface.sh deliberately keeps the WIDE window: there, seeing a box
# that is no longer live makes it REFUSE to close, which is the safe direction.
#
# THIS ONE KNOB SPANS SITES WHOSE FAILURE DIRECTIONS ARE OPPOSITE, so it is a floor
# at some of them and a ceiling at others, and repl_box_tail_lines below is the only
# place allowed to narrow it:
#   boot wait (wait-for-session.sh), cmux-paste.sh's --wait-box loop — the REPL is
#     still COMING UP and the screen is growing under us. Too small there is a HARD
#     TIMEOUT on a boot that was fine, so these keep the constant and never measure.
#   the two delivery box gates on an EXISTING REPL (cmux-reuse-surface.sh, and
#     cmux-paste.sh's final gate) — the measurement is contemporaneous, and too
#     small only costs a fresh surface. These narrow to the pane's real height.
HOTLINE_BOX_TAIL_LINES="${HOTLINE_BOX_TAIL_LINES:-12}"

# cmux_read_live <what> <flag> <handle> [lines] — the live tail, on stdout.
#   0 — read succeeded    1 — cmux could not read it    2 — refused (empty handle)
cmux_read_live() {
  local what="$1" flag="$2" handle="$3" lines="${4:-$HOTLINE_READ_LINES}"
  cmux_handle_ok "$what" "$handle" || return 2
  cmux read-screen "$flag" "$handle" --scrollback --lines "$lines" 2>/dev/null || return 1
}

# --- How tall is the pane, exactly? ------------------------------------------
# cmux_screen_rows <what> <flag> <handle> — the number of rows the surface is
# showing right now, on stdout; nothing (and non-zero) when it cannot be measured.
#
# THE ONE BARE `cmux read-screen` IN THE TRANSPORT, and it is not the bug the rest
# of this file exists to prevent. A bare read returns what the surface is CURRENTLY
# SHOWING, so its CONTENT follows the user's scroll — which is why every read that
# is judged goes through cmux_read_live instead. Only its LINE COUNT is used here,
# and a scrolled viewport has exactly as many rows as an unscrolled one, so scroll
# immunity is untouched.
#
# Verified live on cmux 0.64.22, four panes of different heights: a bare read
# returns the showing rows with trailing blanks stripped, and `tail -n <that count>`
# of a `--scrollback --lines 9999` read of the same surface is byte-identical to it
# (62/239, 13/13, 83/310, 71/1522 rows). That equality is the whole contract: this
# number is the right width for tailing a TEXT capture.
#
# DO NOT SUBSTITUTE THE RENDER GRID'S `rows`. `terminal.replay --anchor screen`
# reports the pane height INCLUDING trailing blank rows (84 for all three of the
# panes above), while a text capture has those stripped — so tailing that many
# lines reaches 20+ rows into history, i.e. the exact failure this measurement is
# meant to end.
#
# `grep -c ''` rather than `wc -l` because tail counts a final line with no
# trailing newline as a line and wc does not; the counter has to agree with the
# consumer.
#
# MEMOIZED PER HANDLE for the life of the process: the callers poll (cmux-paste's
# box loop reads every 0.4s), and one extra cmux call per invocation is the budget
# this was designed to fit. A pane does not change height mid-call, and where the
# SCREEN is still growing the constant is used instead — see HOTLINE_BOX_TAIL_LINES.
_HOTLINE_ROWS_KEY=""
_HOTLINE_ROWS_VAL=""
cmux_screen_rows() {
  local what="$1" flag="$2" handle="$3" key rows
  [[ -n "${HOTLINE_SCREEN_TAIL_EXPLICIT:-}" ]] && return 1
  cmux_handle_ok "$what" "$handle" || return 2
  key="$flag $handle"
  if [[ "$key" != "$_HOTLINE_ROWS_KEY" ]]; then
    _HOTLINE_ROWS_KEY="$key"
    _HOTLINE_ROWS_VAL=""
    rows=$(cmux read-screen "$flag" "$handle" 2>/dev/null | grep -c '' || true)
    [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -gt 0 ]] && _HOTLINE_ROWS_VAL="$rows"
  fi
  [[ -z "$_HOTLINE_ROWS_VAL" ]] && return 1
  printf '%s' "$_HOTLINE_ROWS_VAL"
}

# cmux_screen_rows_forget — drop the memo, so the next call measures again.
#
# For the one thing that genuinely changes a pane's row count mid-call: CONTENT
# ARRIVING. A screen that is not yet full GROWS as output is appended, so a height
# measured before a paste is a lower bound on the screen after it — and a window
# sized to the smaller number would drop the newest rows, which is exactly where a
# just-submitted turn's echo lives. Re-measuring after delivery keeps every window
# reaching zero rows into history, which is what makes "this marker was not on the
# pre-paste screen" mean fresh rather than merely out-of-window.
cmux_screen_rows_forget() {
  _HOTLINE_ROWS_KEY=""
  _HOTLINE_ROWS_VAL=""
}

# repl_screen_tail_lines [rows] — how many rows of a capture are "the live screen".
# The measurement when there is one, the constant when there is not, so an
# unmeasurable pane keeps exactly today's behavior instead of a guess.
repl_screen_tail_lines() {
  local rows="${1:-}"
  if [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -gt 0 ]]; then
    printf '%s' "$rows"
  else
    printf '%s' "$HOTLINE_SCREEN_TAIL_LINES"
  fi
}

# repl_box_tail_lines [rows] — the bottom-of-screen window a box gate may believe.
# NEVER WIDER than HOTLINE_BOX_TAIL_LINES (that is the point of the tight window)
# and never wider than the live screen either: on a pane showing fewer rows than
# that constant, the rest of the window is HISTORY, where a dead REPL's last frame
# still holds its NBSP-padded box render with the shell prompt that replaced it
# underneath — and believing that hands a work order to the shell. So: the smaller
# of the two. Only the gates judging an EXISTING REPL pass rows; see the constant.
repl_box_tail_lines() {
  local rows="${1:-}" box="$HOTLINE_BOX_TAIL_LINES"
  if [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -gt 0 ]] && [[ "$rows" -lt "$box" ]]; then
    printf '%s' "$rows"
  else
    printf '%s' "$box"
  fi
}

# repl_screen_tail <capture> [lines] — the live screen rows out of a scroll-immune
# read. Pass a tighter count where a wider window would be actively wrong (the boot
# wait does: on a surface a previous REPL has been through, an old NBSP-padded box
# render 20 rows up would report a REPL that exited).
repl_screen_tail() {
  printf '%s\n' "$1" | tail -n "${2:-$HOTLINE_SCREEN_TAIL_LINES}"
}

# --- Sending: line hygiene and a refusal on an empty handle -------------------
# cmux_send_live <what> <flag> <handle> <text...>
cmux_send_live() {
  local what="$1" flag="$2" handle="$3"
  shift 3
  cmux_handle_ok "$what" "$handle" || return 2
  cmux send "$flag" "$handle" "$@"
}

# A cmux surface's input line is not ours alone — the user's keystrokes land
# there too. On 2026-08-26 three stray characters arrived ahead of a launch
# command and the surface ran `rkebash /tmp/…`, so the callee never booted and
# the caller burned its whole 60s budget on a diagnostic that blamed
# --allowedTools. Ctrl-U (0x15) kills the line in every shell line editor, so the
# command we send is the whole command.
#
# Raw byte through the TEXT path, exactly like the Ctrl-C clear in
# cmux-reuse-surface.sh: `send-key ctrl+u` does not reach the program, the same
# way `send-key ctrl+c` does not.
cmux_clear_input_line() {
  local what="$1" flag="$2" handle="$3"
  cmux_handle_ok "$what" "$handle" || return 2
  cmux send "$flag" "$handle" $'\025' >/dev/null 2>&1 || true
  return 0
}

# repl_launch_error_line <screen> [launch-script-path] — echoes the shell
# diagnostic that says our launch line was MANGLED, so the boot wait can fail
# fast with the real text instead of timing out and guessing.
#
# Scoped to errors that name OUR line, not any error the surface's rc files print
# on startup: the mangle PREPENDS the user's keystrokes to the command, so the
# offending token still contains `bash` (or the script's own name) —
# "zsh: command not found: rkebash". A broken `.zshrc` complaining about `pyenv`
# is not our problem and must not fail the boot.
#
# THE MATCH IS ON THE OFFENDING TOKEN, not on the line. "Somewhere on this line
# there is a not-found phrase, and somewhere on this line there is the word bash"
# also describes a claude tool result that shells out — `bash: /tmp/x: No such file
# or directory` echoed inside a Bash(...) block, in a REPL that is up and healthy —
# and treating that as a refused launch line fails a boot that already happened. So
# the token carrying `bash` (or the script's basename) has to sit immediately beside
# the phrase, in either order, which is how the two shells word it:
#   zsh   → "zsh: command not found: rkebash"        (phrase, then token)
#   bash  → "bash: rkebash: command not found"       (token, then phrase)
#   either→ "bash: /tmp/…/hotline-launch-abc: No such file or directory"
# `bash: pyenv: command not found` has `bash` only as the SHELL'S OWN NAME, in front
# of a token that is not ours, and no longer matches.
#
# The `|| true` is required, not defensive: a caller running under `set -o pipefail`
# would take a no-match grep (the normal case — most screens hold no error) as a
# failed command and die there.
#
# repl_launch_error_lines echoes EVERY such diagnostic. The boot wait counts them,
# because its one-shot retry has to tell a NEW refusal from the one it already
# retried on: after Ctrl-U + re-send, the old error line is still on screen and
# still matches, and reading it a second time abandoned a surface where claude was
# in fact booting (claude-plugins-r465.7 review).
repl_launch_error_lines() {
  local screen="$1" script="${2:-}" base="" tok="bash" phrase
  [[ -n "$script" ]] && base="$(basename "$script")"
  [[ -n "$base" ]] && tok="bash|$base"
  phrase='command not found|no such file or directory'
  printf '%s\n' "$screen" \
    | grep -aiE "($phrase)[[:space:]]*:[[:space:]]*[^[:space:]]*($tok)|:[[:space:]]*[^[:space:]]*($tok)[^[:space:]]*[[:space:]]*:[[:space:]]*($phrase)" \
    || true
}

# The most recent one, which is the text a diagnostic quotes.
repl_launch_error_line() {
  repl_launch_error_lines "$@" | tail -1 || true
}

# --- Reading the REPL's state off its rendered screen -------------------------
# The claude REPL draws its input box as a `❯`-prefixed line between two
# horizontal rules at the bottom of the screen. The transcript above it echoes
# prior user turns with the SAME glyph, so more than one candidate line is
# usually on screen. Two things disambiguate, in order of reliability:
#   1. The live box pads its glyph with a NO-BREAK SPACE (U+00A0); the transcript
#      echoes use a plain space. Verified on claude 2.1.221.
#   2. Failing that, the box is the LAST such line — it's drawn at the bottom.
# Byte escapes rather than \u so this still works under bash 3.2 (macOS system).
REPL_BOX_GLYPH=$'\xe2\x9d\xaf'   # ❯
REPL_BOX_NBSP=$'\xc2\xa0'        # the box's padding after the glyph

# Echoes whatever text is sitting in the REPL's input box ("" when it's empty).
input_box_content() {
  local screen="$1" line
  line=$(printf '%s\n' "$screen" | grep "^${REPL_BOX_GLYPH}${REPL_BOX_NBSP}" | tail -1) || true
  if [[ -z "$line" ]]; then
    line=$(printf '%s\n' "$screen" | grep "^${REPL_BOX_GLYPH}" | tail -1) || true
  fi
  [[ -z "$line" ]] && return 0
  line="${line#"$REPL_BOX_GLYPH"}"
  # Strip the padding (NBSP and/or ordinary blanks) between glyph and content.
  while :; do
    case "$line" in
      "$REPL_BOX_NBSP"*) line="${line#"$REPL_BOX_NBSP"}" ;;
      " "*)              line="${line# }" ;;
      $'\t'*)            line="${line#$'\t'}" ;;
      *)                 break ;;
    esac
  done
  # An untouched REPL renders a greyed placeholder hint INSIDE an empty box.
  # read-screen strips the colour that would distinguish it, so match its shape.
  case "$line" in
    'Try "'*) return 0 ;;
  esac
  printf '%s' "$line" | sed 's/[[:space:]]*$//'
}

# --- Placeholder or unsent input? --------------------------------------------
# input_box_is_placeholder <workspace-uuid> <surface-uuid>
#
# True when the text visible in the box is Claude Code's PLACEHOLDER rather than
# something a human (or a previous paste) left unsent (claude-plugins-ff6g).
#
# input_box_content cannot answer this and never will: `cmux read-screen` is plain
# text, and placeholder and input are byte-identical there. Claude Code renders the
# placeholder DIM (SGR 2) and real input at normal intensity, so the discriminator
# is the attribute the text read throws away. The cmux RPC `terminal.replay`
# (capability `terminal.render_grid.v1`) keeps it: row_spans carry a style_id into a
# styles table with `faint`, `inverse` and `bold`, plus the cursor's row/column.
#
# A VISIBLE PLACEHOLDER PROVES THE INPUT VALUE IS EMPTY — the TUI draws it only
# when `value.length === 0` — which is why this is worth an RPC. There are at least
# three placeholder strings (`Try "<example>"` on a virgin session, `Press up to
# edit queued messages`, `Message @<agent>…`) and a suggested-prompt ghost is
# arbitrary text, so no shape match can cover them; the dim attribute covers all of
# them at once.
#
# THE FENCE IS ASYMMETRIC, so this predicate FAILS CLOSED. A false negative costs
# one fresh surface. A false positive pastes a work order on top of a human's
# half-typed words. So: an RPC error, a cmux without `terminal.render_grid.v1`,
# unparseable JSON, no box row on the grid, or one scrap of non-dim content all
# return false — "treat it as real text", which is the behavior a caller has
# without this predicate at all. Ambiguity is always real text.
#
# The one tolerated exception to "every span is faint" is a SINGLE non-faint
# `inverse` cell at the cursor column: a focused terminal renders the placeholder's
# first character as the block cursor instead of dim. Real input never renders dim,
# so the tolerance cannot turn typed text into a placeholder.
input_box_is_placeholder() {
  local ws="$1" surf="$2" here rpc grid
  [[ -z "$ws" || -z "$surf" ]] && return 1
  command -v python3 >/dev/null 2>&1 || return 1
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  rpc="$here/cmux-rpc.py"
  [[ -f "$rpc" ]] || return 1
  # A cmux that cannot render a styled grid cannot answer the question. Checked
  # against the capability list rather than inferred from an empty reply, so an
  # older cmux degrades to today's behavior instead of to a guess.
  cmux capabilities 2>/dev/null | grep -qF 'terminal.render_grid.v1' || return 1
  # anchor:"screen" so a scrolled pane does not answer with a frozen viewport.
  # `terminal.replay`'s default anchor is "viewport", which FOLLOWS the user's
  # scroll — the box row would then be a scrolled-up echo, or absent. anchor
  # "screen" is scroll-immune by contract (MobileTerminalRenderGridAnchorRegistry
  # .swift:11-14, "primary-screen scrolling never round-trips") and confirmed live
  # on cmux 0.64.22. Requested only when cmux advertises it, so an older cmux
  # keeps today's behavior instead of getting an unknown param.
  # `|| true` because a cmux WITHOUT the capability makes this list return 1, and a
  # caller running under `set -e` outside a conditional would die on it.
  local anchor=()
  cmux capabilities 2>/dev/null \
    | grep -qF 'terminal.render_grid.screen_anchor.v1' && anchor=(--anchor screen) || true
  # cmux-rpc.py sends snake_case params only and exits 4 when the reply's
  # surface_id is not the surface we asked for; both matter here, because a
  # camelCase key or a dropped target returns the FOCUSED surface's grid with
  # ok:true and we would judge a bystander's input box (claude-plugins-r465.9).
  grid=$(python3 "$rpc" --method terminal.replay --workspace "$ws" --surface "$surf" \
    ${anchor[@]+"${anchor[@]}"} 2>/dev/null) || return 1
  [[ -z "$grid" ]] && return 1
  # Exit 0 only for "every non-blank span after the box glyph is dim".
  printf '%s' "$grid" | python3 -c '
import json, sys

# Escapes, not literals: the NO-BREAK SPACE below is one keystroke away from an
# ordinary space and nothing downstream would notice the swap.
GLYPH = "\u276f"   # the box glyph
NBSP = "\u00a0"    # the padding the box draws after it
PREFIX = GLYPH + NBSP

def nope():
    sys.exit(1)

try:
    doc = json.load(sys.stdin)
except Exception:
    nope()
if not isinstance(doc, dict) or doc.get("ok") is not True:
    nope()
grid = (doc.get("result") or {}).get("render_grid")
if not isinstance(grid, dict):
    nope()
spans = grid.get("row_spans")
styles = grid.get("styles")
if not isinstance(spans, list):
    nope()
# A list of {"id": N, ...} live; a mapping is accepted so a shape change degrades
# to a lookup miss (which fails closed) rather than to a crash.
table = {}
if isinstance(styles, list):
    for st in styles:
        if isinstance(st, dict) and "id" in st:
            table[st["id"]] = st
elif isinstance(styles, dict):
    for key, st in styles.items():
        if isinstance(st, dict):
            table[st.get("id", key)] = st
else:
    nope()

# The LIVE box row, by the same two tells input_box_content uses: the glyph padded
# with U+00A0 (a transcript echo of a past turn pads with an ordinary space), and
# failing a tie, the LAST such row — the box is drawn at the bottom. No box row on
# the grid is an answer this predicate must not give, so it fails closed.
box = None
for span in spans:
    if not isinstance(span, dict):
        continue
    row, text = span.get("row"), span.get("text")
    if span.get("column") == 0 and isinstance(text, str) and text.startswith(PREFIX):
        if isinstance(row, int) and (box is None or row > box):
            box = row
if box is None:
    nope()

cursor = grid.get("cursor")
cursor_col = None
if isinstance(cursor, dict) and cursor.get("row") == box:
    cursor_col = cursor.get("column")

# Every non-blank piece of the box row after the glyph, with the style it carries.
# The glyph span is not always the glyph alone: cmux merges same-style runs, so a
# box holding typed text renders the glyph, its U+00A0 padding and the first word as
# ONE span, while a dim placeholder must split off from the non-dim glyph. Stripping the prefix and
# judging the remainder by ITS OWN style therefore handles both without a special
# case for either.
pieces = []
for span in spans:
    if not isinstance(span, dict) or span.get("row") != box:
        continue
    text = span.get("text")
    col = span.get("column")
    style = table.get(span.get("style_id"))
    if not isinstance(text, str) or style is None:
        nope()
    if col == 0 and text.startswith(PREFIX):
        text = text[len(PREFIX):].lstrip()
        col = len(PREFIX)
    if not text.strip():
        continue
    pieces.append((col, text, style))

# An empty box has nothing to reclassify; the caller already treats it as empty.
if not pieces:
    nope()

tolerated = 0
for col, text, style in pieces:
    if style.get("faint") is True:
        continue
    if (style.get("inverse") is True and len(text) == 1 and tolerated == 0
            and cursor_col is not None and col == cursor_col):
        tolerated = 1
        continue
    nope()
sys.exit(0)
' || return 1
}

# True when the screen shows a turn in flight. Two independent markers, because
# neither is dependable alone: "esc to interrupt" is absent in some versions
# (including 2.1.221), and the spinner's wording changes between releases — but
# a RUNNING spinner always carries a live elapsed-time parenthetical, e.g.
# "✶ Dilly-dallying… (5s · ↓ 124 tokens · …)", whereas the finished one does not
# ("✻ Baked for 12s"). Callers add a screen-stability check on top.
repl_looks_busy() {
  local screen="$1"
  grep -qi 'esc to interrupt' <<<"$screen" && return 0
  grep -qE '\([0-9]+s[ )·]' <<<"$screen" && return 0
  return 1
}

# The post-interrupt "what now?" state. It is not busy, but it is not accepting
# a follow-up on our terms either — anything we type becomes an answer to that
# question rather than a new turn (claude-plugins-06ws acceptance criteria).
repl_is_interrupted() {
  grep -qiE 'What should Claude do instead|Request interrupted by user' <<<"$1"
}

# True when the REPL has drawn its input box at all — i.e. the TUI is up and
# accepting keystrokes, not merely "the process started".
#
# input_box_content cannot answer this: it returns "" for an EMPTY box and ""
# for no box at all, and an empty box is the normal state of a just-booted REPL.
# Callers need the distinction because a payload delivered to a surface that has
# NOT exec'd claude does not vanish — it goes to the shell.
#
# THE NO-BREAK SPACE IS LOAD-BEARING HERE, not a nicety. This match requires the
# glyph to be followed by U+00A0, the padding claude's box draws and a shell
# prompt does not. `❯` is the default prompt character of starship, pure and
# several oh-my-zsh themes, all of which pad with an ordinary space — so a bare
# `^❯` match says "a shell prompt is on screen" just as readily as "the REPL is
# up". That is not a missed-delivery bug: `terminal.paste` with
# submit_key:"return" would type the whole work order at a shell and press
# Enter, and the shell would run it.
#
# input_box_content's fallback to a bare `^❯` (above) is safe for the opposite
# reason: there, matching a shell prompt makes it report parked text, and every
# caller treats parked text as a reason to refuse. Presence has no such
# asymmetry, so it gets the strict form only.
#
# The cost of strictness is a claude release that stops padding with NBSP: box
# presence would stop firing, and delivery would refuse with a diagnostic
# instead of proceeding. That is the correct direction to fail in.
repl_box_present() {
  grep -q "^${REPL_BOX_GLYPH}${REPL_BOX_NBSP}" <<<"$1"
}

# True when the screen is Claude Code's STARTUP TRUST DIALOG rather than a REPL
# waiting for work.
#
# WHY A SCREEN READ AND NOT A LIFECYCLE STATE. This dialog is the one startup gate
# neither transport's readiness signal catches. Verified live on CC 2.1.251 / herdr
# 0.8.0 in a fresh `git init` directory: `agent start` returned
# `interactive_ready:true, agent_status:"idle"` with the dialog on screen — true, in
# its own terms (the dialog does take keystrokes) and useless as permission to
# deliver. The dialog's DEFAULT option is `No, exit`, so a submitted payload answers
# it that way and the callee exits: no user turn, no transcript, the whole work order
# gone (claude-plugins-59ry).
#
# THE CAPTURE IS WHITESPACE-NORMALIZED BEFORE MATCHING, and that is not tidiness —
# without it this predicate does not work at all on a narrow pane. The dialog is one
# reflowed paragraph plus two reflowed option lines, so the terminal decides where the
# line breaks fall. Live-caught on a ~16-column herdr pane (five panes in one
# workspace): `Yes, I trust this\n   folder` and a header broken after
# `Quick safety\n check`, where every raw substring test below missed and the gate
# waved the payload through into the dialog. Collapsing every run of whitespace —
# newlines included — to one space puts the phrases back the way they are read.
#
# THE MATCH IS AN OR OVER WORDINGS, DELIBERATELY, and it leans towards firing. CC has
# already reworded this dialog once (`Do you trust the files in this folder?` →
# `Quick safety check: …` / `Yes, I trust this folder`), and the two directions are
# not symmetric: a false positive costs a refusal with sent:false, which the caller
# recovers from by trusting the directory and re-dialing, while a false negative kills
# the callee. So any one of these phrasings is enough, and a future wording should be
# ADDED here rather than replacing what is already known.
#
# Not scroll-immune — herdr has no equivalent of cmux's scrollback read, so a pane a
# human has scrolled could hand back a stale capture. Only the first-contact gate uses
# this, against an agent seconds old that nobody has touched, and a stale read fails
# back to the pre-existing behavior rather than to something worse.
repl_trust_dialog_present() {
  local flat
  flat=$(tr -s '[:space:]' ' ' <<<"$1")
  [[ "$flat" == *"Quick safety check"*        ]] && return 0
  [[ "$flat" == *"I trust this folder"*       ]] && return 0
  [[ "$flat" == *"trust the files in this"*   ]] && return 0
  return 1
}

# repl_trust_dialog_refusal <read-flag> <handle> [callee-cwd] — the refusal text,
# on stdout.
#
# ONE wording, because TWO cmux gates catch this dialog and a caller must not learn
# different things from them. wait-for-session.sh's boot wait catches it for a quick
# call or a work order; cmux-paste.sh's --wait-box loop catches it for a CONFERENCE,
# which never reaches the boot wait at all (dial.sh step 5b → cmux-call.sh →
# cmux-paste.sh --wait-box) and so burned the whole box budget and blamed a REPL that
# never drew a box, with `trust` unmentioned — the original claude-plugins-6y0s
# symptom, on the one path the first fix did not cover.
#
# Both gates run BEFORE anything is written to the pane, which is why the text can
# promise that nothing was delivered and that re-dialing is safe. Do not call it from
# a post-paste site. herdr's own refusal (herdr-prompt.sh) is deliberately NOT this
# string: it names herdr's readiness lie and `agent attach`, and its payload sits in
# pending_paste.md rather than being pasted in a later step.
repl_trust_dialog_refusal() {
  local flag="$1" handle="$2" cwd="${3:-}"
  printf '%s' "Claude Code's startup TRUST DIALOG is on screen in cmux ${handle} for ${cwd:-the callee cwd} — trust that directory (run \`claude\` in it once and answer 'Yes, I trust this folder'), then re-dial. NOTHING WAS DELIVERED: the prompt is pasted in a later step, so the callee has received nothing and re-dialing is safe. The dialog takes keystrokes and its default option is 'No, exit', so a payload sent into it would have answered that and killed the callee. HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS does not cover this gate — directory trust is not a permission mode. Read the pane with: cmux read-screen ${flag} ${handle} --scrollback --lines 80."
}

# --- Boot-wait budget --------------------------------------------------------
# ONE definition of how long we wait for a callee's REPL to become usable.
#
# wait-for-session.sh waits for the REPL to exist; cmux-paste.sh waits for its
# input box to be drawn. Same event, so the same budget — and it lived in two
# places with two different values, so the documented 60s default and the actual
# 20s box wait disagreed.
HOTLINE_BOOT_TIMEOUT_CMUX="${HOTLINE_BOOT_TIMEOUT_CMUX:-60}"
HOTLINE_BOOT_TIMEOUT_HEADLESS="${HOTLINE_BOOT_TIMEOUT_HEADLESS:-30}"

# --- The per-call nonce ------------------------------------------------------
# Every hotline delivery carries a [CALL_ID: <nonce>] the receiver echoes back in
# its STATUS lines. wait-for-response.sh correlates on it, delivery confirmation
# proves itself with it, and superseded-surface cleanup uses it as identity proof.
#
# Both halves live here because all three delivery paths need them identically and
# the copies had already drifted: two of them split the prompt on the first space
# ANYWHERE in it, so a multi-line follow-up beginning with "/" got the nonce
# spliced into the middle of its second line.
hotline_mint_call_id() {
  openssl rand -hex 8 2>/dev/null \
    || od -A n -N 8 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n' \
    || date +%s%N | sha256sum 2>/dev/null | cut -c1-16
}

# --- The callee's session id -------------------------------------------------
# A fresh claude session UUID, for a launcher that must PRESET the callee's
# session id rather than read it back. Presetting is not a convenience: the whole
# filesystem response channel is ~/.claude/projects/<encoded-cwd>/<session>.jsonl,
# so the id has to be known BEFORE the callee boots.
#
# uuidgen (macOS/Linux), /proc/sys/kernel/random/uuid and /dev/urandom are tried in
# order so this degrades gracefully on minimal systems. Prints nothing when all
# three are unavailable; callers must handle an empty result.
#
# cmux-call-async.sh carries this same derivation inline and is deliberately NOT
# refactored onto this helper here: the phase that added herdr had "the cmux path
# stays bit-identical" as its hard constraint, and a pure extraction is still a
# diff in the file that constraint is about. Adopt this there the next time that
# launcher is touched for its own reasons, and delete the inline copy.
hotline_mint_session_uuid() {
  local b
  uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' \
    || cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || {
         b=$(od -A n -N 16 -t x1 /dev/urandom | tr -d ' \n')
         printf '%s-%s-4%s-%x%s-%s\n' \
           "${b:0:8}" "${b:8:4}" "${b:13:3}" \
           "$(( (16#${b:16:1} & 0x3) | 0x8 ))" "${b:17:3}" "${b:20:12}"
       } \
    || true
}

# hotline_inject_call_id <nonce> <prompt> → the prompt with the nonce in it.
#
# Two placements, and which one applies is not a style choice:
#
#   Slash-command prompt → INLINE, immediately after the command token. claude
#     parses a slash command only when the input STARTS with it, and only while it
#     is still literal `/…` text: a header line above `/hotline:hotline-ringing`,
#     or a paste large enough that CC collapses the whole buffer to a
#     `[Pasted text +N lines]` placeholder, both leave the input not starting with
#     `/` and turn the invocation into plain text. Keeping the nonce inline is only
#     half of what protects the slash; the other half is delivery — cmux-paste.sh
#     sends first contact as two pastes so the invocation line renders verbatim
#     while the body's placeholder expands inside the command args (claude-plugins-pmgb).
#
#   Anything else → its OWN leading line. wait-for-response.sh matches the nonce
#     on screen, and at the start of a line it can never be broken across a
#     rendered line wrap the way a mid-line match could be. Safe because the paste
#     arrives as one atomic bracketed paste (verified live: 76-line payload, one
#     user turn, nonce line intact).
#
# "Slash command" is judged on the FIRST TOKEN OF THE FIRST LINE, and only when
# that token looks like a command name. `/Users/JT/Code/x` starts with a slash and
# is not one — the character class excludes `/` after the first character, so a
# path falls through to the header-line form instead of having the nonce spliced
# after its first directory component.
#
# ONE predicate owns that judgement because two callers must agree on it forever:
# hotline_inject_call_id places the nonce INLINE only for a slash command, and
# cmux-paste.sh splits delivery into two pastes only for a slash command. The
# inline-nonce placement and the split-paste delivery are the same design invariant
# seen from two ends — a regex that drifted between them would break it silently.
# ("Extract the helper the moment a second caller appears.")
hotline_is_slash_command_first_line() {
  local first_line="$1" token
  token="${first_line%%[[:space:]]*}"
  [[ "$token" =~ ^/[A-Za-z0-9][A-Za-z0-9:._-]*$ ]]
}

# hotline_payload_needs_split_delivery <payload-file> — 0 when this payload must be
# delivered as TWO writes into the callee's input box rather than one.
#
# The composite BOTH transports turn on, and both halves of it matter: a slash-command
# first line, and a body beneath it. With no slash there is no invocation for a
# `[Pasted text +N lines]` placeholder to swallow; with no body the payload is one
# short line that arrives verbatim anyway, so splitting would buy nothing and add a
# round trip.
#
# TWO MECHANISMS, ONE QUESTION. cmux-paste.sh splits one `terminal.paste` into two;
# herdr-prompt.sh splits a `pane send-text` from an `agent prompt`. What they must
# never disagree about is WHEN — and they already did: the split landed on the cmux
# path (37a216d) and the herdr backend (f87501e) never adopted it, so every herdr
# first contact carrying a multi-line work order delivered `/hotline:hotline-ringing`
# as plain text and the ringing protocol never engaged (claude-plugins-fvhx).
hotline_payload_needs_split_delivery() {
  local payload_file="$1"
  [[ -r "$payload_file" ]] || return 1
  hotline_is_slash_command_first_line "$(sed -n '1p' "$payload_file")" || return 1
  [[ $(sed -n '2,$p' "$payload_file" | wc -c) -gt 0 ]]
}

# hotline_is_followup_invocation <prompt> — 0 when the prompt is dial.sh's
# `/hotline:hotline-ringing [FOLLOW_UP] …` re-invocation, before or after the nonce
# is spliced in.
#
# The producer and the registration readers must agree on it. A follow-up carries
# the same [MODE:]/[CALLER:]/[SESSION:] tags as first contact — they are what the
# ringing skill reads — but it is not a new call: the launchers that register first
# contact off those tags would otherwise `set` the cached connection afresh
# (exchange_count back to 1, `started` reset) and log a second dial-history entry.
# Judged on the first line only, so a work order that merely mentions the tag is
# never mistaken for one.
hotline_is_followup_invocation() {
  local first_line="${1%%$'\n'*}"
  [[ "$first_line" == '/hotline:hotline-ringing '* ]] || return 1
  [[ "$first_line" == *' [FOLLOW_UP]'* ]]
}

hotline_inject_call_id() {
  local nonce="$1" prompt="$2" first_line rest_lines token remainder
  first_line="${prompt%%$'\n'*}"
  token="${first_line%%[[:space:]]*}"
  if hotline_is_slash_command_first_line "$first_line"; then
    # Everything after the command token, first line only; the rest is untouched.
    remainder="${first_line#"$token"}"
    if [[ "$prompt" == *$'\n'* ]]; then
      rest_lines="${prompt#*$'\n'}"
      printf '%s [CALL_ID: %s]%s\n%s' "$token" "$nonce" "$remainder" "$rest_lines"
    else
      printf '%s [CALL_ID: %s]%s' "$token" "$nonce" "$remainder"
    fi
  else
    printf '[CALL_ID: %s]\n%s' "$nonce" "$prompt"
  fi
}

# --- Where does a surface live? ----------------------------------------------
# Echoes "<workspace-uuid> <surface-uuid>" for a cmux surface handle.
#
# Needed by two callers with different reasons and one shared hazard. `terminal.paste`
# addresses a surface by UUID *and* wants its workspace UUID; `cmux close-surface`
# fails "Surface not found: <uuid>" without --workspace even for a surface
# read-screen reads happily in the same breath. Neither is stored anywhere, and a
# cache written by an older plugin version may hold a positional `surface:N` ref
# rather than a UUID — so both resolve through the tree, here, once.
#
# Exit codes are distinct because the callers report them differently: an
# unreadable tree is a cmux problem, an absent handle means the surface is gone.
#   0 — resolved; "workspace-uuid surface-uuid" on stdout
#   3 — the cmux tree could not be read
#   4 — the handle is not in the tree
cmux_surface_address() {
  local handle="$1" tree addr
  tree=$(cmux tree --all --json --id-format both 2>/dev/null) || return 3
  [[ -z "$tree" ]] && return 3
  # --id-format both reports each surface's stable `id` alongside its positional
  # `ref`, so one lookup serves both handle shapes. Case-insensitive on the UUID:
  # cmux emits uppercase, but a handle that has been through another tool may not
  # have survived that way.
  addr=$(jq -r --arg h "$handle" '
    .windows[]?.workspaces[]? as $ws
    | $ws.panes[]?.surfaces[]?
    | select((.id // "") == $h
             or (.ref // "") == $h
             or ((.id // "") | ascii_downcase) == ($h | ascii_downcase))
    | "\($ws.id) \(.id)"' <<<"$tree" 2>/dev/null | head -1)
  [[ -z "$addr" || "$addr" == *null* ]] && return 4
  printf '%s' "$addr"
}

# Echoes "<workspace-uuid> <surface-uuid>" for a WORKSPACE handle — the surface a
# payload should go to when the call was placed by workspace rather than by
# surface (the detached placement, which names a workspace tab). The detached
# launcher calls this to RESOLVE the surface it then records, so a follow-up can
# re-address the tab instead of opening another one (claude-plugins-zaus).
#
# Same tree, same output shape, same exit codes as cmux_surface_address, so a
# caller can use either and pass the result on unchanged. Both live here because
# this file is where tree reading is centralised: dial.sh grew its own inline copy
# of this walk, and a second reader of the same JSON is precisely the drift this
# repo has already paid for twice in the transcript parser.
#
# selected_surface_id is preferred (it is the tab the user is looking at) with the
# pane's first surface as the fallback, because a tree that reports surfaces
# without a selection still has exactly one place a fresh launch can be.
#   0 — resolved; "workspace-uuid surface-uuid" on stdout
#   3 — the cmux tree could not be read
#   4 — the workspace is not in the tree, or holds no surface
cmux_workspace_current_surface() {
  local handle="$1" tree addr
  tree=$(cmux tree --all --json --id-format both 2>/dev/null) || return 3
  [[ -z "$tree" ]] && return 3
  addr=$(jq -r --arg w "$handle" '
    .windows[]?.workspaces[]?
    | select((.ref // "") == $w
             or (.id // "") == $w
             or ((.id // "") | ascii_downcase) == ($w | ascii_downcase))
    | . as $ws
    | $ws.panes[]?
    | (.selected_surface_id // .surfaces[0].id // empty) as $s
    | "\($ws.id) \($s)"' <<<"$tree" 2>/dev/null | head -1)
  [[ -z "$addr" || "$addr" == *null* ]] && return 4
  printf '%s' "$addr"
}

# --- Closing a surface: the container is not optional ------------------------
# cmux_close_surface_scoped <what> <surface-handle>
#
# `cmux close-surface` resolves --surface INSIDE a workspace context that defaults
# to the caller's inherited $CMUX_WORKSPACE_ID, so a surface UUID that read-screen
# reads happily in the same breath still fails "Surface not found: <uuid>" without
# --workspace (verified live, cmux 0.64.20). Three cleanup sites passed --surface
# alone under `|| true`, so every one of them silently no-op'd and leaked the
# surface it meant to reap (claude-plugins-5k43).
#
# The workspace comes off the tree rather than from a stored value, via
# cmux_surface_address: that resolves a positional `surface:N` ref as well as a
# UUID (an orphan parsed out of an opener's stderr is positional), and it answers
# with BOTH ids as UUIDs, which is what keeps the call pointed at the same thing
# after refs renumber.
#
# The echoed `OK surface:<ref> workspace:<n>` names the NEWLY SELECTED surface,
# not the one closed, so it is no confirmation of anything and is discarded.
#
#   0 — closed
#   1 — the surface's workspace could not be resolved (tree unreadable, or the
#       surface is already gone); diagnostic in $CMUX_CLOSE_ERR
#   2 — cmux refused the close; diagnostic in $CMUX_CLOSE_ERR
#
# CMUX_CLOSE_ERR is published rather than printed so a caller can route it into
# the call dir instead of a swallowed stderr — a cleanup failure that only exists
# as a discarded stream is the failure mode this replaces.
CMUX_CLOSE_ERR=""
cmux_close_surface_scoped() {
  local what="$1" handle="${2:-}" addr ws surf out
  CMUX_CLOSE_ERR=""
  cmux_handle_ok "$what" "$handle" || { CMUX_CLOSE_ERR="empty surface handle"; return 1; }
  addr=$(cmux_surface_address "$handle")
  case $? in
    0) ;;
    3) CMUX_CLOSE_ERR="could not read the cmux tree to resolve surface $handle's workspace"; return 1 ;;
    *) CMUX_CLOSE_ERR="surface $handle is not in the cmux tree, so its workspace is unknown"; return 1 ;;
  esac
  ws="${addr%% *}"; surf="${addr##* }"
  if ! out=$(cmux close-surface --workspace "$ws" --surface "$surf" 2>&1); then
    CMUX_CLOSE_ERR="cmux close-surface --workspace $ws --surface $surf refused: $(printf '%s' "$out" | tr '\n\r\t' '   ' | cut -c1-140)"
    return 2
  fi
  return 0
}
