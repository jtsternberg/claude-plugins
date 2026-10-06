#!/usr/bin/env bash
# =============================================================================
# The cmux-events primitives in repl-state.sh: contract and the five traps.
#
# These functions are the single binding of
# plugins/cmux-cli/skills/using-cmux-cli/references/events.md into the dial
# transport — every script that migrates off read-screen polling consumes them,
# so a regression here is a regression in all of them at once. Duplicating the
# `cmux events | jq` incantation per caller is the failure this exists to
# prevent; this repo has lost time to exactly that in the transcript parser,
# twice.
#
# `cmux` is a PATH stub serving canned NDJSON. No real cmux, no network.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$HOTLINE_DIR/scripts/repl-state.sh"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

echo "hotline events primitives"

[[ -f "$LIB" ]] || { echo "repl-state.sh missing at $LIB"; echo "0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  - jq absent; skipping"; echo "0 passed, 0 failed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# --- The cmux stub -----------------------------------------------------------
# Serves $CMUX_FRAMES for `events`, prefixed by the ack frame and a heartbeat
# (trap 1: both must be tolerated) and followed by the timeout line on stderr.
# `--snapshot` answers the capability probe. It deliberately IGNORES --name, so
# every name narrowing under test is the client-side guard doing the work.
cat > "$TMP/bin/cmux" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  [[ -n "${CMUX_STUB_VERSION:-}" ]] && echo "cmux $CMUX_STUB_VERSION (108) [dda24fbd2]"
  exit 0
fi
[[ "$1" != "events" ]] && exit 0
shift
snap=0; noack=0
for a in "$@"; do
  [[ "$a" == "--snapshot" ]] && snap=1
  [[ "$a" == "--no-ack"   ]] && noack=1
done
if [[ -n "${CMUX_STUB_EVENTS_FAIL:-}" ]]; then
  echo "Error: unknown subcommand 'events'" >&2; exit 2
fi
if [[ $snap -eq 1 ]]; then
  # Real cmux 0.64.25 prints ONLY the ack for --snapshot, so --no-ack suppresses
  # the single line it emits and yields nothing. A stub that printed it anyway hid
  # a cmux_events_seq that could never return a marker against real cmux.
  [[ $noack -eq 1 ]] && exit 0
  printf '{"type":"ack","resume":{"oldest_seq":1,"latest_seq":%s,"gap":false}}\n' \
    "${CMUX_STUB_LATEST_SEQ:-500}"
  exit 0
fi
if [[ $noack -eq 0 ]]; then
  printf '{"type":"ack","resume":{"oldest_seq":1,"latest_seq":500,"gap":false}}\n'
fi
[[ -n "${CMUX_FRAMES:-}" && -f "$CMUX_FRAMES" ]] && cat "$CMUX_FRAMES"
echo "Error: Timed out waiting for a matching event" >&2
exit 0
STUB
chmod +x "$TMP/bin/cmux"

# shellcheck source=../scripts/repl-state.sh
set +u; source "$LIB"; set -u

frames() { CMUX_FRAMES="$TMP/frames.ndjson"; export CMUX_FRAMES; : > "$CMUX_FRAMES"; }
frame()  { printf '%s\n' "$1" >> "$CMUX_FRAMES"; }

SURF="F41D2405-AAAA"
WS="4C7FA894-BBBB"

# --- 1. Capability probe -----------------------------------------------------
unset HOTLINE_CMUX_EVENTS; HOTLINE_CMUX_EVENTS_CACHE=""
cmux_events_supported && pass "capability probe says yes on a cmux that answers --snapshot" \
  || fail "capability probe says yes on a cmux that answers --snapshot"

HOTLINE_CMUX_EVENTS_CACHE=""; CMUX_STUB_EVENTS_FAIL=1 
if CMUX_STUB_EVENTS_FAIL=1 HOTLINE_CMUX_EVENTS_CACHE="" bash -c "
  set -euo pipefail; source '$LIB'
  cmux_events_supported && exit 1 || exit 0" 2>/dev/null; then
  pass "capability probe says no on a cmux with no events subcommand (fallbacks stay live)"
else
  fail "capability probe says no on a cmux with no events subcommand"
fi
unset CMUX_STUB_EVENTS_FAIL; HOTLINE_CMUX_EVENTS_CACHE=""

HOTLINE_CMUX_EVENTS=0 bash -c "set -euo pipefail; source '$LIB'; cmux_events_supported" 2>/dev/null \
  && fail "HOTLINE_CMUX_EVENTS=0 forces the fallback path" \
  || pass "HOTLINE_CMUX_EVENTS=0 forces the fallback path (how the suites drive both)"

# --- 2. cmux_events_seq ------------------------------------------------------
GOT=$(CMUX_STUB_LATEST_SEQ=647 cmux_events_seq || true)
[[ "$GOT" == "647" ]] \
  && pass "cmux_events_seq reads latest_seq off the snapshot ack" \
  || fail "cmux_events_seq reads latest_seq off the snapshot ack" "got '$GOT'"

# A failed probe must NOT yield 0: passing --after 0 would replay all retained
# history and read unrelated frames as caused by our send.
if CMUX_STUB_EVENTS_FAIL=1 bash -c "
  set -euo pipefail; source '$LIB'
  out=\$(cmux_events_seq || true); [[ -z \"\$out\" ]]" 2>/dev/null; then
  pass "cmux_events_seq yields nothing (never 0) when it cannot read a marker"
else
  fail "cmux_events_seq yields nothing (never 0) when it cannot read a marker"
fi

# --- 3. Trap 1: the ack frame and the stderr timeout line ---------------------
frames
frame "{\"name\":\"surface.created\",\"seq\":5,\"pane_id\":\"PANE-1\",\"surface_id\":\"$SURF\"}"
GOT=$(cmux_wait_surface_created "PANE-1" 1 || true)
if [[ -n "$GOT" ]] && printf '%s' "$GOT" | jq -e '.seq == 5' >/dev/null 2>&1; then
  pass "an ack frame on stdout and a timeout line on stderr do not corrupt the result"
else
  fail "an ack frame on stdout and a timeout line on stderr do not corrupt the result" "got '$GOT'"
fi

GOT=$(cmux_wait_surface_created "PANE-OTHER" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a surface.created for another pane is not a match" \
  || fail "a surface.created for another pane is not a match" "got '$GOT'"

# --- 4. Trap 4: agent.hook.* fires twice -------------------------------------
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":10,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"received\"}}"
frame "{\"name\":\"agent.hook.Stop\",\"seq\":11,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"completed\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 11 and .payload.phase == "completed"' >/dev/null 2>&1; then
  pass "the turn-end waiter takes the 'completed' phase, not the 'received' one"
else
  fail "the turn-end waiter takes the 'completed' phase, not the 'received' one" "got '$GOT'"
fi

# Only a "received" phase in the window is NOT a turn end.
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":10,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"received\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a 'received'-only Stop is not reported as a finished turn" \
  || fail "a 'received'-only Stop is not reported as a finished turn" "got '$GOT'"

# --- 4b. The ATTRIBUTABLE turn end ------------------------------------------
# cmux_wait_turn_end answers "something finished"; a response waiter needs "the
# callee I dialed finished", and the two are not the same question. Its surface
# match falls back to a null surface_id — which most real Stop frames carry — so
# any session's turn end satisfies it, including the operator's own.
#
# cmux_wait_session_turn_end discriminates on payload.session_id and on nothing
# else. payload.cwd was measured out of the running twice over: one directory
# carried agent.hook frames for two different sessions (and a hotline callee runs
# in the CALLER'S cwd by definition), and one session emitted frames under two
# different cwds after cd'ing. The first wakes a waiter on somebody else's turn;
# the second blocks it through a turn end that really happened.
TE_UUID="6f0b4990-a577-434c-9940-6b3c10d5affa"
TE_COMPOSITE="cmux-feed-v1:Y2xhdWRl:$(printf '%s' "$TE_UUID" | base64 | tr -d '\n')"
OTHER_UUID="b2d244b2-b67b-4f3b-bbc5-ed9217e6e691"
OTHER_COMPOSITE="cmux-feed-v1:Y2xhdWRl:$(printf '%s' "$OTHER_UUID" | base64 | tr -d '\n')"
SHARED_CWD="/Users/JT/Code/claude-plugins"

frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":90,\"surface_id\":null,\"payload\":{\"phase\":\"received\",\"session_id\":\"$TE_COMPOSITE\",\"cwd\":\"$SHARED_CWD\"}}"
frame "{\"name\":\"agent.hook.Stop\",\"seq\":91,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"$TE_COMPOSITE\",\"cwd\":\"$SHARED_CWD\"}}"
GOT=$(cmux_wait_session_turn_end "$TE_UUID" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 91' >/dev/null 2>&1; then
  pass "our session's completed Stop satisfies the attributable wait (null surface_id and all)"
else
  fail "our session's completed Stop satisfies the attributable wait" "got '$GOT'"
fi

# THE CASE THE WEAK WAITER GETS WRONG: a turn ending in ANOTHER session, in the
# same directory, with a null surface_id. Measured as the common shape.
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":92,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"$OTHER_COMPOSITE\",\"cwd\":\"$SHARED_CWD\"}}"
GOT=$(cmux_wait_session_turn_end "$TE_UUID" 1 || true)
[[ -z "$GOT" ]] \
  && pass "another session's turn end in the SAME cwd does not satisfy it" \
  || fail "another session's turn end in the SAME cwd does not satisfy it" "got '$GOT'"

# …and the weak waiter demonstrably does accept it, which is why the strict one
# exists. Asserted so nobody "simplifies" the caller back onto it.
GOT=$(cmux_wait_turn_end "A-SURFACE-THAT-NEVER-APPEARS" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 92' >/dev/null 2>&1; then
  pass "cmux_wait_turn_end still matches ANY session (documented, and why the strict one exists)"
else
  fail "cmux_wait_turn_end still matches ANY session" "got '$GOT'"
fi

# A callee that exits instead of settling is still a turn that ended; waiting for
# a Stop that will never come is how a poller hangs to its deadline.
frames
frame "{\"name\":\"agent.hook.SessionEnd\",\"seq\":93,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"$TE_COMPOSITE\"}}"
GOT=$(cmux_wait_session_turn_end "$TE_UUID" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 93' >/dev/null 2>&1; then
  pass "a SessionEnd counts as our turn ending"
else
  fail "a SessionEnd counts as our turn ending" "got '$GOT'"
fi

# Only the "received" half in the window is not a turn end (trap 4).
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":94,\"surface_id\":null,\"payload\":{\"phase\":\"received\",\"session_id\":\"$TE_COMPOSITE\"}}"
GOT=$(cmux_wait_session_turn_end "$TE_UUID" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a 'received'-only Stop is not our turn ending either" \
  || fail "a 'received'-only Stop is not our turn ending either" "got '$GOT'"

# A build that stops wrapping the feed id must not silently turn this into a wait
# that never returns.
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":95,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"$TE_UUID\"}}"
GOT=$(cmux_wait_session_turn_end "$TE_UUID" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 95' >/dev/null 2>&1; then
  pass "a bare (unwrapped) session id still satisfies the attributable wait"
else
  fail "a bare (unwrapped) session id still satisfies the attributable wait" "got '$GOT'"
fi

# No session id to attribute to → refuse outright (rc 2) rather than wait on
# anything that moves. A caller with no session must keep its screen fallback.
# Stdout redirected, not just stderr: a regression here MATCHES, and the frame it
# prints would otherwise land mid-line in this suite's own output — which is how
# the control for this case first read as "did not fire".
if bash -c "set -euo pipefail; source '$LIB'; cmux_wait_session_turn_end '' 1; exit 9" >/dev/null 2>&1; then
  fail "an empty session id refuses rather than matching anything" "returned 0"
else
  RC=$?
  [[ $RC -eq 2 ]] \
    && pass "an empty session id refuses outright (rc 2), never matching anything" \
    || fail "an empty session id refuses outright (rc 2)" "rc=$RC"
fi

# --- 5. Trap 5: a null surface_id must not be dropped ------------------------
frames
frame "{\"name\":\"agent.hook.Stop\",\"seq\":12,\"surface_id\":null,\"payload\":{\"phase\":\"completed\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
if printf '%s' "$GOT" | jq -e '.seq == 12' >/dev/null 2>&1; then
  pass "an unattributed (null surface_id) Stop still counts as a turn end"
else
  fail "an unattributed (null surface_id) Stop still counts as a turn end" "got '$GOT'"
fi

# --- 6. Trap 2b: the client-side name guard ----------------------------------
# The stub ignores --name, so only the client-side guard can reject this.
frames
frame "{\"name\":\"agent.hook.SessionStart\",\"seq\":20,\"surface_id\":\"$SURF\",\"payload\":{\"phase\":\"completed\",\"session_id\":\"S1\"}}"
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a SessionStart cannot satisfy a turn-end wait (client-side name guard)" \
  || fail "a SessionStart cannot satisfy a turn-end wait" "got '$GOT'"

# A frame with no .name at all (the ack shape) must never match.
frames
frame '{"type":"ack","resume":{"latest_seq":1}}'
GOT=$(cmux_wait_turn_end "$SURF" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a frame with no .name never matches" \
  || fail "a frame with no .name never matches" "got '$GOT'"

# --- 7. Submit lengths: the four readings ------------------------------------
frames
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ -z "$GOT" ]] \
  && pass "no submit frame → nothing submitted (the payload sits in the box)" \
  || fail "no submit frame → nothing submitted" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":30,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":43}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ "$GOT" == "43" ]] \
  && pass "one frame, length under 240 → reported verbatim and exact" \
  || fail "one frame, length under 240 → reported verbatim and exact" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":31,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":19}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ "$GOT" == "19" ]] \
  && pass "a short length is reported verbatim, so a caller can call byte loss" \
  || fail "a short length is reported verbatim" "got '$GOT'"

# Passed through as-is, never read as a verdict: this primitive does not know which
# cmux produced the frame, and on a pre-0.65.0 one 240 is the preview's length.
frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":35,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":240}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ "$GOT" == "240" ]] \
  && pass "a 240 is passed through unchanged; interpreting it is the caller's job" \
  || fail "a 240 is passed through unchanged" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":32,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":20}}"
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":33,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":23}}"
GOT=$(cmux_submit_lengths "$WS" 1 | tr '\n' ',' || true)
[[ "$GOT" == "20,23," ]] \
  && pass "two frames for one send → fragmentation, both lengths reported" \
  || fail "two frames for one send → fragmentation" "got '$GOT'"

# Another workspace's submit is not ours.
frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":34,\"workspace_id\":\"OTHER-WS\",\"payload\":{\"message_length\":43}}"
GOT=$(cmux_submit_lengths "$WS" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a submit in another workspace is not counted as ours" \
  || fail "a submit in another workspace is not counted as ours" "got '$GOT'"

# --- 7a. The version gate and the measures primitive -------------------------
for v_case in "0.65.0:0" "0.65.1:0" "0.66.0:0" "0.100.0:0" "1.0.0:0" "0.64.25:1" "0.9.9:1" "garbage:1" ":1"; do
  v="${v_case%:*}"; want="${v_case##*:}"
  GOT=$(CMUX_STUB_VERSION="$v" bash -c 'source "$1"; cmux_has_true_message_length; echo $?' _ "$LIB")
  [[ "$GOT" == "$want" ]] \
    && pass "version gate: '${v:-<empty>}' → exit $want" \
    || fail "version gate: '${v:-<empty>}'" "want $want, got '$GOT'"
done

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":40,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":1260,\"message_preview\":\"abc…\"}}"
GOT=$(cmux_submit_measures "$(printf '%s' "$WS" | tr 'a-z' 'A-Z')" 1 | jq -c . || true)
[[ "$GOT" == '{"len":1260,"old_cap":false}' ]] \
  && pass "measures: a length above the preview's is a true length (workspace id case-folded)" \
  || fail "measures: a length above the preview's is a true length" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":41,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":4,\"message_preview\":\"abc…\"}}"
GOT=$(cmux_submit_measures "$WS" 1 | jq -c . || true)
[[ "$GOT" == '{"len":4,"old_cap":true}' ]] \
  && pass "measures: an ellipsized preview whose length IS message_length is flagged old_cap" \
  || fail "measures: old_cap signature" "got '$GOT'"

frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":42,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":43,\"message_preview\":\"short\"}}"
GOT=$(cmux_submit_measures "$WS" 1 | jq -c . || true)
[[ "$GOT" == '{"len":43,"old_cap":false}' ]] \
  && pass "measures: an unellipsized preview is never old_cap" \
  || fail "measures: unellipsized preview" "got '$GOT'"

# --- 7b. cmux_prompt_ingests: how many turns did the callee actually ingest? --
# The COUNT is the answer here, and its attribution is the whole point:
# workspace.prompt.submitted (section 7) carries no surface_id and no session_id,
# and a side-by-side hotline call puts caller and callee in ONE workspace, so a
# count taken from it reports fragmentation whenever the operator types into their
# own pane. These fixtures use the shapes of a real capture on 0.64.25: two phases
# per occurrence, a composite session id, an upper-case surface uuid.
ING_SURF="19702726-22F7-403C-9647-0F6FB86DC9F2"
ING_UUID="6f0b4990-a577-434c-9940-6b3c10d5affa"
ING_COMPOSITE="cmux-feed-v1:Y2xhdWRl:$(printf '%s' "$ING_UUID" | base64 | tr -d '\n')"
ing() { # <seq> <surface> <session-composite> <phase>
  frame "{\"name\":\"agent.hook.UserPromptSubmit\",\"seq\":$1,\"surface_id\":\"$2\",\"payload\":{\"phase\":\"$4\",\"session_id\":\"$3\",\"surface_id\":\"$2\",\"cwd\":\"/x\"}}"
}

frames
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "0" ]] \
  && pass "no ingest frame in the window → no turns counted" \
  || fail "no ingest frame in the window → no turns counted" "got '$GOT'"

frames
ing 70 "$ING_SURF" "$ING_COMPOSITE" received
ing 71 "$ING_SURF" "$ING_COMPOSITE" completed
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "1" ]] \
  && pass "both phases of ONE occurrence count as one turn (trap 4)" \
  || fail "both phases of ONE occurrence count as one turn" "got '$GOT'"

frames
ing 72 "$ING_SURF" "$ING_COMPOSITE" completed
ing 73 "$ING_SURF" "$ING_COMPOSITE" completed
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "2" ]] \
  && pass "two turns for one delivery → the fragmentation the count exists to show" \
  || fail "two turns for one delivery → fragmentation" "got '$GOT'"

# The surface half of the attribution: the same session reported against another
# surface (a `claude --resume` puts one uuid in a second surface) is not ours.
frames
ing 74 "$ING_SURF" "$ING_COMPOSITE" completed
ing 75 "82F23F19-F2E0-4F95-B616-FBAAD5CF3896" "$ING_COMPOSITE" completed
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "1" ]] \
  && pass "a turn in another surface is not counted, even for our own session" \
  || fail "a turn in another surface is not counted" "got '$GOT'"

# The session half: the caller's own REPL sharing our workspace is a DIFFERENT
# session, which is the measured shape of a side-by-side call.
frames
ing 76 "$ING_SURF" "$ING_COMPOSITE" completed
ing 77 "$ING_SURF" "cmux-feed-v1:Y2xhdWRl:$(printf '%s' 'b2d244b2-b67b-4f3b-bbc5-ed9217e6e691' | base64 | tr -d '\n')" completed
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "1" ]] \
  && pass "another session's turn is not counted as ours" \
  || fail "another session's turn is not counted as ours" "got '$GOT'"

# The handle a caller holds comes from the cmux tree and the frame's from the hook
# bridge. A uuid differing only in case must not silently match nothing.
frames
ing 78 "$ING_SURF" "$ING_COMPOSITE" completed
GOT=$(cmux_prompt_ingests "$(printf '%s' "$ING_SURF" | tr 'A-Z' 'a-z')" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "1" ]] \
  && pass "the surface match is case-folded (tree case vs hook-bridge case)" \
  || fail "the surface match is case-folded" "got '$GOT'"

# With no session known the surface is the ONLY discriminator, and it must still
# reject a foreign surface rather than degrade into a workspace-wide count.
frames
ing 79 "$ING_SURF" "$ING_COMPOSITE" completed
ing 80 "82F23F19-F2E0-4F95-B616-FBAAD5CF3896" "$ING_COMPOSITE" completed
GOT=$(cmux_prompt_ingests "$ING_SURF" "" 1 | grep -c . || true)
[[ "$GOT" == "1" ]] \
  && pass "with no session passed, the surface alone still scopes the count" \
  || fail "with no session passed, the surface alone still scopes the count" "got '$GOT'"

# A bare (unwrapped) session id must keep matching, so a cmux build that stops
# wrapping the feed id does not silently zero every count.
frames
ing 81 "$ING_SURF" "$ING_UUID" completed
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "1" ]] \
  && pass "a bare (unwrapped) session id still matches" \
  || fail "a bare (unwrapped) session id still matches" "got '$GOT'"

# Trap 2b: the stub ignores --name, so only the client-side guard can reject a
# workspace.prompt.submitted standing in for an ingest.
frames
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":82,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":240}}"
GOT=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
[[ "$GOT" == "0" ]] \
  && pass "a workspace.prompt.submitted cannot satisfy an ingest count" \
  || fail "a workspace.prompt.submitted cannot satisfy an ingest count" "got '$GOT'"

# --- 7c. The two scopings DISAGREE, and that disagreement is the whole point ---
# THIS CASE EXISTS TO STOP A "SIMPLIFICATION". Measured on two real dials:
#
#   placement   cmux_prompt_ingests(surface+session)   cmux_submit_lengths(ws)
#   detached                    1                                1
#   side                        1                                2      ← truth is 1
#
# A DETACHED callee gets its OWN workspace, so the workspace-scoped count is right
# BY ACCIDENT there — anyone who tests only detached sees the two agree and
# concludes the cheaper primitive is fine. On the DEFAULT side placement the caller
# and callee share one workspace (measured live: one workspace_id over two
# session_ids on two surface_ids), and then the workspace-scoped count reports
# fragmentation for a clean delivery.
#
# So the fixture below is the SIDE topology, and the assertion is that the two
# primitives disagree on it. If a future change makes them agree, either the
# attribution was dropped or the fixture stopped modelling a shared workspace —
# both of which this case should refuse.
frames
ing 83 "$ING_SURF" "$ING_COMPOSITE" completed
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":84,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":240}}"
# The caller's own REPL, in the SAME workspace, on a different surface + session.
ing 85 "82F23F19-F2E0-4F95-B616-FBAAD5CF3896" "$OTHER_COMPOSITE" completed
frame "{\"name\":\"workspace.prompt.submitted\",\"seq\":86,\"workspace_id\":\"$WS\",\"payload\":{\"message_length\":240}}"
ATTRIBUTED=$(cmux_prompt_ingests "$ING_SURF" "$ING_UUID" 1 | grep -c . || true)
WS_SCOPED=$(cmux_submit_lengths "$WS" 1 | grep -c . || true)
[[ "$ATTRIBUTED" == "1" ]] \
  && pass "shared workspace: the attributed count sees ONE turn (the truth)" \
  || fail "shared workspace: the attributed count sees ONE turn" "got '$ATTRIBUTED'"
[[ "$WS_SCOPED" == "2" ]] \
  && pass "shared workspace: the workspace-scoped count sees TWO — why 3a does not use it" \
  || fail "shared workspace: the workspace-scoped count sees TWO" "got '$WS_SCOPED'"
[[ "$ATTRIBUTED" != "$WS_SCOPED" ]] \
  && pass "the two scopings disagree on a shared workspace, and must keep disagreeing" \
  || fail "the two scopings disagree on a shared workspace" \
       "both reported '$ATTRIBUTED' — attribution dropped, or the fixture stopped sharing a workspace"

# --- 8. The substituted-target check -----------------------------------------
frames
frame "{\"name\":\"surface.input_sent\",\"seq\":40,\"payload\":{\"params\":{\"text_length\":25},\"result\":{\"surface_id\":\"$SURF\"}}}"
cmux_send_landed_on "$SURF" 1 \
  && pass "a send whose result.surface_id is the intended surface verifies" \
  || fail "a send whose result.surface_id is the intended surface verifies"

frames
frame "{\"name\":\"surface.input_sent\",\"seq\":41,\"payload\":{\"params\":{\"text_length\":25},\"result\":{\"surface_id\":\"CALLERS-OWN-SURFACE\"}}}"
cmux_send_landed_on "$SURF" 1 \
  && fail "a send that landed on the caller's own surface is caught" \
        "reported a match against the wrong surface" \
  || pass "a send that landed on the caller's own surface is caught"

# --- 9. Session start --------------------------------------------------------
# `payload.session_id` is NOT a bare uuid. cmux reports a composite feed id,
# `cmux-feed-v1:<base64 agent name>:<base64 session uuid>`, measured live on
# 0.64.25. These cases use that shape: with a bare id they passed while the
# function could not match or return anything usable against real cmux.
UUID="d1d722b9-d8c1-42ef-987e-468ce2662c73"
UUID_B64=$(printf '%s' "$UUID" | base64 | tr -d '\n')
COMPOSITE="cmux-feed-v1:Y2xhdWRl:${UUID_B64}"

frames
frame "{\"name\":\"agent.hook.SessionStart\",\"seq\":50,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"$COMPOSITE\",\"cwd\":\"/Users/x/proj\"}}"
GOT=$(cmux_wait_session_start "/Users/x/proj" 1 || true)
[[ "$GOT" == "$UUID" ]] \
  && pass "session start DECODES the composite feed id to the bare session uuid" \
  || fail "session start DECODES the composite feed id to the bare session uuid" "got '$GOT'"

GOT=$(cmux_wait_session_start "/Users/x/other" 1 || true)
[[ -z "$GOT" ]] \
  && pass "a session start in another cwd is not ours" \
  || fail "a session start in another cwd is not ours" "got '$GOT'"

# A cwd is not unique to a call: the operator's own claude session in the same
# directory emits an identical-looking SessionStart. With a preset known, the
# match must be exact — and it has to see through the base64 wrapper to make it.
GOT=$(cmux_wait_session_start "/Users/x/proj" 1 "$UUID" || true)
[[ "$GOT" == "$UUID" ]] \
  && pass "a preset uuid matches inside the composite, and comes back BARE" \
  || fail "a preset uuid matches inside the composite, and comes back BARE" "got '$GOT'"

# The composite must never reach the caller: session_id.txt, transcript paths and
# the call registry all need the uuid.
case "$GOT" in
  cmux-feed-v1:*) fail "the composite feed id never reaches the caller" "got '$GOT'" ;;
  *)              pass "the composite feed id never reaches the caller" ;;
esac

GOT=$(cmux_wait_session_start "/Users/x/proj" 1 "00000000-0000-0000-0000-000000000000" || true)
[[ -z "$GOT" ]] \
  && pass "another session booting in the same cwd is not mistaken for ours" \
  || fail "another session booting in the same cwd is not mistaken for ours" "got '$GOT'"

# Defensive: a build that stops wrapping the id must not silently kill signal D.
frames
frame "{\"name\":\"agent.hook.SessionStart\",\"seq\":51,\"surface_id\":null,\"payload\":{\"phase\":\"completed\",\"session_id\":\"$UUID\",\"cwd\":\"/Users/x/proj\"}}"
GOT=$(cmux_wait_session_start "/Users/x/proj" 1 "$UUID" || true)
[[ "$GOT" == "$UUID" ]] \
  && pass "a bare (unwrapped) session id still matches a preset" \
  || fail "a bare (unwrapped) session id still matches a preset" "got '$GOT'"

# --- 10. The wait returns when the FRAME arrives, not when the window ends ----
# This is the case that decides whether migrating off read-screen polling is an
# improvement at all. cmux holds the stream open for its whole --timeout, so a
# reader that merely stops reading still pays for the window: the first
# implementation here returned the right frame 6s into a 6s window for a frame
# delivered at 0s, which would have made a 600s turn-end wait cost 600s.
#
# Modelling that needs a stub that STAYS OPEN after emitting the match, not one
# that `cat`s a file and exits — a stub that has already exited cannot hold
# anyone up, so the earlier shape of this case passed with every guard removed.
STREAM_STUB="$TMP/bin/cmux"
cp "$STREAM_STUB" "$TMP/cmux.orig"
cat > "$STREAM_STUB" <<'STREAM'
#!/usr/bin/env bash
[[ "$1" != "events" ]] && exit 0
shift
for a in "$@"; do
  [[ "$a" == "--snapshot" ]] && { printf '{"type":"ack","resume":{"latest_seq":500}}\n'; exit 0; }
done
printf '{"name":"agent.hook.Stop","seq":60,"surface_id":"%s","payload":{"phase":"completed"}}\n' "$STREAM_SURF"
# A real `cmux events --timeout N` holds the connection for the whole window and
# then exits, so honour the flag — a stub that sleeps a fixed time instead makes
# the no-match case look like an overrun that is really the stub's own nap.
hold="${STREAM_HOLD:-8}"
prev=""
for a in "$@"; do [[ "$prev" == "--timeout" ]] && hold="$a"; prev="$a"; done
sleep "$hold"
STREAM
chmod +x "$STREAM_STUB"
export STREAM_SURF="$SURF" STREAM_HOLD=8

S=$(date +%s)
GOT=$(bash -c "set -euo pipefail; source '$LIB'; cmux_wait_turn_end '$SURF' 8" 2>/dev/null || true)
ELAPSED=$(( $(date +%s) - S ))

if [[ -n "$GOT" ]]; then
  pass "the turn-end wait gets its frame off a stream that stays open"
else
  fail "the turn-end wait gets its frame off a stream that stays open" "got nothing"
fi

if [[ $ELAPSED -le 3 ]]; then
  pass "it returns when the frame arrives (${ELAPSED}s), not when the 8s window ends"
else
  fail "it returns when the frame arrives, not when the window ends" \
       "took ${ELAPSED}s of an 8s window — the wait is paying for the whole window"
fi

# And it must survive `set -euo pipefail`, which is what every dial script runs.
if bash -c "set -euo pipefail; source '$LIB'; out=\$(cmux_wait_turn_end '$SURF' 8); [[ -n \"\$out\" ]]" 2>/dev/null; then
  pass "the wait survives set -euo pipefail"
else
  fail "the wait survives set -euo pipefail" "non-zero status propagated out"
fi

# No match in the window must still cost only the window, and yield nothing.
S=$(date +%s)
GOT=$(bash -c "set -euo pipefail; source '$LIB'; cmux_wait_turn_end 'SOME-OTHER-SURFACE' 2 || true" 2>/dev/null || true)
ELAPSED=$(( $(date +%s) - S ))
if [[ -z "$GOT" && $ELAPSED -le 5 ]]; then
  pass "no matching frame yields nothing and does not overrun the window (${ELAPSED}s)"
else
  fail "no matching frame yields nothing and does not overrun the window" \
       "got '$GOT' after ${ELAPSED}s"
fi

# The producer must not be left running once we have the answer: an orphaned
# `cmux events --timeout 600` per wait is a leak, and the fast-return shape that
# used process substitution measured the same 0s while leaking one every time.
#
# Match on the STUB'S PATH, not on the FIFO: cmux's fifo is a `>` redirect and
# never appears in its argv, so a pattern built from the fifo name matches
# nothing and the check passes with the kill removed. The path is under $TMP, so
# this can never match the operator's own cmux processes.
STREAM_HOLD=20 bash -c "set -euo pipefail; source '$LIB'; cmux_wait_turn_end '$SURF' 20" >/dev/null 2>&1 || true
LEAKED=$(pgrep -f "$TMP/bin/cmux" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${LEAKED:-0}" -eq 0 ]]; then
  pass "the event producer is not left orphaned after an early return"
else
  fail "the event producer is not left orphaned after an early return" \
       "$LEAKED still running against a 20s window we returned from immediately"
  pkill -f "$TMP/bin/cmux" 2>/dev/null || true
fi

cp "$TMP/cmux.orig" "$STREAM_STUB"
unset STREAM_SURF STREAM_HOLD

# --- 11. The empty-handle guard names the right surface ----------------------
# The guard must name the CALLER'S OWN pane. A cmux CLI verb falls back to the
# inherited $CMUX_*_ID, so that is where an empty handle delivers; only a
# malformed `cmux rpc` resolves against the FOCUSED surface. Blaming the focused
# surface here is what sends the next debugger to the wrong pane, so the wording
# is asserted, not left to drift.
MSG=$(cmux_handle_ok "a probe" "" 2>&1 || true)
if printf '%s' "$MSG" | grep -qi 'FOCUSED'; then
  fail "the empty-handle guard names the caller's own pane, not the focused surface" \
       "message still blames the focused surface"
elif printf '%s' "$MSG" | grep -qi 'THIS pane' && printf '%s' "$MSG" | grep -q 'CMUX_\*_ID'; then
  pass "the empty-handle guard names the caller's own pane, not the focused surface"
else
  fail "the empty-handle guard names the caller's own pane, not the focused surface" \
       "got: $MSG"
fi

cmux_handle_ok "a probe" "$SURF" \
  && pass "a non-empty handle passes the guard" \
  || fail "a non-empty handle passes the guard"

echo
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
