#!/usr/bin/env bash
# =============================================================================
# Regression tests for transcript-extract.sh — the JSONL-transcript reader that
# replaces terminal screen-scraping for hotline's cmux transport
# (claude-plugins-0pwc). Drives synthetic transcripts through the extractor and
# asserts the exit-code contract (0 done / 10 working / 11 not-submitted) and
# the reconstructed response body.
# =============================================================================
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/transcript-extract.sh"
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

NONCE="abc123def456"
mkf() { local f; f=$(mktemp); printf '%s\n' "$1" > "$f"; echo "$f"; }

# Reusable event snippets ------------------------------------------------------
USER_NONCE='{"type":"user","isSidechain":false,"sessionId":"sess-1","message":{"content":"[CALL_ID: '"$NONCE"'] please help"}}'
USER_NONCE_ARRAY='{"type":"user","isSidechain":false,"sessionId":"sess-1","message":{"content":[{"type":"text","text":"[CALL_ID: '"$NONCE"'] please help"}]}}'
WIP='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$NONCE"'"}]}}'
BODY='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"the real answer line 1\nthe real answer line 2\n\nSTATUS: DONE call_id='"$NONCE"'"}]}}'
THINKING='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"secret reasoning that must NOT leak"}]}}'
SIDECHAIN='{"type":"assistant","isSidechain":true,"sessionId":"sess-1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"subagent chatter that must NOT leak"}]}}'

# Case 1: not submitted (no user event carries the nonce) → exit 11 -------------
F=$(mkf '{"type":"user","isSidechain":false,"sessionId":"sess-1","message":{"content":"unrelated"}}')
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 11 ]] && pass "exit 11 when nonce never appears in a user event" \
  || fail "exit 11 when nonce never appears" "got exit $?"
rm -f "$F"

# Case 2: submitted, no terminal STATUS yet → exit 10 --------------------------
F=$(mkf "$USER_NONCE
$WIP")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 10 ]] && pass "exit 10 when submitted but still working" \
  || fail "exit 10 when submitted but still working" "got exit $?"
rm -f "$F"

# Case 3: complete turn → exit 0, body reconstructed, STATUS lines stripped ----
F=$(mkf "$USER_NONCE
$WIP
$BODY")
OUT=$(bash "$SCRIPT" "$F" "$NONCE" 2>&1); RC=$?
RESP=$(printf '%s' "$OUT" | jq -r '.response' 2>/dev/null)
SID=$(printf '%s' "$OUT" | jq -r '.session_id' 2>/dev/null)
[[ $RC -eq 0 ]] && pass "exit 0 on terminal STATUS" || fail "exit 0 on terminal STATUS" "rc=$RC out=$OUT"
[[ "$RESP" == *"the real answer line 1"* && "$RESP" == *"line 2"* ]] \
  && pass "response body reconstructed" || fail "response body reconstructed" "resp=$RESP"
[[ "$RESP" != *"STATUS:"* ]] && pass "STATUS sentinel lines stripped from body" \
  || fail "STATUS sentinel lines stripped" "resp=$RESP"
[[ "$SID" == "sess-1" ]] && pass "session_id extracted" || fail "session_id extracted" "sid=$SID"
rm -f "$F"

# Case 4: thinking + sidechain must NOT leak into the body ---------------------
F=$(mkf "$USER_NONCE
$THINKING
$SIDECHAIN
$WIP
$BODY")
RESP=$(bash "$SCRIPT" "$F" "$NONCE" 2>/dev/null | jq -r '.response' 2>/dev/null)
[[ "$RESP" != *"secret reasoning"* ]] && pass "thinking blocks excluded" \
  || fail "thinking blocks excluded" "resp=$RESP"
[[ "$RESP" != *"subagent chatter"* ]] && pass "sidechain (subagent) turns excluded" \
  || fail "sidechain turns excluded" "resp=$RESP"
rm -f "$F"

# Case 5: array-form user content still matches the nonce ----------------------
F=$(mkf "$USER_NONCE_ARRAY
$WIP
$BODY")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "array-form user.message.content matches nonce" \
  || fail "array-form user content matches nonce" "got exit $?"
rm -f "$F"

# Case 6: WIP reset — a false-start attempt then a fresh WIP+retry. Only the
# prose after the LAST WORK_IN_PROGRESS survives (matches the caller's documented
# "body buffer resets on every WIP" semantics).
ABORTED='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$NONCE"'\nfalse-start prose that should be discarded"}]}}'
RETRY='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$NONCE"'\nthe real answer\nSTATUS: DONE call_id='"$NONCE"'"}]}}'
F=$(mkf "$USER_NONCE
$ABORTED
$RETRY")
RESP=$(bash "$SCRIPT" "$F" "$NONCE" 2>/dev/null | jq -r '.response' 2>/dev/null)
[[ "$RESP" != *"false-start"* && "$RESP" == *"the real answer"* ]] \
  && pass "buffer resets at each WORK_IN_PROGRESS (only final attempt kept)" \
  || fail "buffer resets at each WORK_IN_PROGRESS" "resp=$RESP"
rm -f "$F"

# Case 7: another call's nonce in the same transcript is ignored ---------------
OTHER='{"type":"user","isSidechain":false,"sessionId":"sess-1","message":{"content":"[CALL_ID: ffff0000ffff0000] different call"}}'
OTHERDONE='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"other answer\nSTATUS: DONE call_id=ffff0000ffff0000"}]}}'
F=$(mkf "$OTHER
$OTHERDONE
$USER_NONCE
$WIP
$BODY")
RESP=$(bash "$SCRIPT" "$F" "$NONCE" 2>/dev/null | jq -r '.response' 2>/dev/null)
[[ "$RESP" == *"the real answer"* && "$RESP" != *"other answer"* ]] \
  && pass "correlates on our nonce, ignores a sibling call's turn" \
  || fail "correlates on our nonce only" "resp=$RESP"
rm -f "$F"

# ---- queued follow-ups (claude-plugins-1jpz) ---------------------------------
# A message sent into a REPL that is mid-turn is ENQUEUED, and claude then
# delivers it one of two ways. Record shapes below are copied from a live
# 2.1.221 transcript (only the prompt text and ids are substituted), because
# neither path writes a `type:"user"` record at delivery time in path (a).
#
#   (a) tool-boundary injection — the queued text is handed to the model INSIDE
#       the busy turn as an `attachment` record whose `.attachment.type` is
#       "queued_command". No user record is ever written, yet the model answers.
#   (b) turn-end flush — the queue drains after the turn ends as a genuine
#       `type:"user"` record (already covered by the cases above).
ENQUEUE='{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-04T22:14:36.125Z","sessionId":"sess-1","content":"[CALL_ID: '"$NONCE"'] please help"}'
DEQUEUE='{"type":"queue-operation","operation":"remove","timestamp":"2026-08-04T22:14:38.681Z","sessionId":"sess-1","content":"[CALL_ID: '"$NONCE"'] please help"}'
QUEUED_ATTACH='{"parentUuid":"cf341cc5-f248-4a10-abee-e89efca05220","isSidechain":false,"attachment":{"type":"queued_command","prompt":"[CALL_ID: '"$NONCE"'] please help","commandMode":"prompt","origin":{"kind":"human"},"timestamp":"2026-08-04T22:14:36.125Z"},"type":"attachment","uuid":"7b3e5d13-7ca1-4f8b-8be2-99bc9d5f5f64","timestamp":"2026-08-04T22:14:36.125Z","session_id":"sess-1","userType":"external","entrypoint":"cli","cwd":"/tmp/ws","sessionId":"sess-1","version":"2.1.221","gitBranch":"HEAD"}'

# Case 8: path (a) end to end — enqueue, mid-turn injection, answer. Never a
# user record, so this used to report exit 11 (never submitted) for a call the
# receiver had already ANSWERED.
F=$(mkf "$ENQUEUE
$DEQUEUE
$QUEUED_ATTACH
$WIP
$BODY")
OUT=$(bash "$SCRIPT" "$F" "$NONCE" 2>&1); RC=$?
RESP=$(printf '%s' "$OUT" | jq -r '.response' 2>/dev/null)
SID=$(printf '%s' "$OUT" | jq -r '.session_id' 2>/dev/null)
[[ $RC -eq 0 && "$RESP" == *"the real answer line 1"* ]] \
  && pass "queued_command injection (no user record) → exit 0 with the body" \
  || fail "queued_command injection → exit 0 with the body" "rc=$RC out=$OUT"
[[ "$SID" == "sess-1" ]] && pass "session_id read from the queued-command path" \
  || fail "session_id read from the queued-command path" "sid=$SID"
rm -f "$F"

# Case 9: enqueued but not yet delivered → submitted, still working (exit 10).
# The enqueue record lands the instant the REPL accepts the keystrokes, so it is
# proof of submit even before either delivery path resolves.
F=$(mkf "$ENQUEUE")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 10 ]] && pass "queue-operation enqueue alone → exit 10 (submitted, queued)" \
  || fail "queue-operation enqueue alone → exit 10" "got exit $?"
rm -f "$F"

# Case 10: injected mid-turn, no answer yet → exit 10.
F=$(mkf "$ENQUEUE
$QUEUED_ATTACH")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 10 ]] && pass "queued_command with no answer yet → exit 10" \
  || fail "queued_command with no answer yet → exit 10" "got exit $?"
rm -f "$F"

# Case 11: the receiver's own STATUS for our call_id is itself proof the message
# arrived — a completed answer must never be reported as never-submitted, even
# if every submit record is missing (truncated/rotated transcript).
F=$(mkf "$BODY")
OUT=$(bash "$SCRIPT" "$F" "$NONCE" 2>&1); RC=$?
RESP=$(printf '%s' "$OUT" | jq -r '.response' 2>/dev/null)
[[ $RC -eq 0 && "$RESP" == *"the real answer line 1"* ]] \
  && pass "assistant STATUS for our call_id alone → exit 0 (never 'not submitted')" \
  || fail "assistant STATUS for our call_id alone → exit 0" "rc=$RC out=$OUT"
rm -f "$F"

# Case 12: only the prose from OUR injection point onward counts. The busy turn
# that swallowed our message keeps emitting its own prose after the enqueue, and
# that prose belongs to the previous task.
PRIOR='{"type":"assistant","isSidechain":false,"sessionId":"sess-1","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"prior-turn prose that must NOT leak"}]}}'
F=$(mkf "$ENQUEUE
$PRIOR
$QUEUED_ATTACH
$BODY")
RESP=$(bash "$SCRIPT" "$F" "$NONCE" 2>/dev/null | jq -r '.response' 2>/dev/null)
[[ "$RESP" == *"the real answer line 1"* && "$RESP" != *"prior-turn prose"* ]] \
  && pass "prose before the injection point does not leak into the body" \
  || fail "prose before the injection point does not leak" "resp=$RESP"
rm -f "$F"

# Case 13: a SIBLING call's queued command is not our submission.
OTHER_ATTACH='{"isSidechain":false,"attachment":{"type":"queued_command","prompt":"[CALL_ID: ffff0000ffff0000] different call","commandMode":"prompt","origin":{"kind":"human"}},"type":"attachment","sessionId":"sess-1"}'
F=$(mkf "$OTHER_ATTACH")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 11 ]] && pass "another call's queued_command is not our submission" \
  || fail "another call's queued_command is not our submission" "got exit $?"
rm -f "$F"

# Case 14: a sidechain (subagent) attachment is not the main REPL accepting our
# message — the same exclusion the response body already applies.
SIDE_ATTACH='{"isSidechain":true,"attachment":{"type":"queued_command","prompt":"[CALL_ID: '"$NONCE"'] please help","commandMode":"prompt"},"type":"attachment","sessionId":"sess-1"}'
F=$(mkf "$SIDE_ATTACH")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 11 ]] && pass "sidechain queued_command is not counted as submission" \
  || fail "sidechain queued_command is not counted as submission" "got exit $?"
rm -f "$F"

# Case 15: preemption still fires on the queued path — a human prompt after our
# injection means our STATUS is never coming.
F=$(mkf "$ENQUEUE
$QUEUED_ATTACH
{\"type\":\"assistant\",\"isSidechain\":false,\"sessionId\":\"sess-1\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"on it\"}]}}
{\"type\":\"user\",\"isSidechain\":false,\"sessionId\":\"sess-1\",\"message\":{\"content\":\"forget that, do the PSR4 migration\"}}")
OUT=$(bash "$SCRIPT" "$F" "$NONCE" 2>/dev/null); RC=$?
[[ $RC -eq 12 && "$OUT" == *"PSR4"* ]] \
  && pass "preemption still detected after a queued-command injection" \
  || fail "preemption still detected after a queued-command injection" "rc=$RC out=$OUT"
rm -f "$F"

# Case 16: tool_result user records inside the swallowing turn are not preemption
# (path (a) injects at a tool boundary, so these always surround our record).
F=$(mkf "$ENQUEUE
{\"type\":\"user\",\"isSidechain\":false,\"sessionId\":\"sess-1\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t0\",\"content\":\"file1\"}]}}
$QUEUED_ATTACH
$WIP")
bash "$SCRIPT" "$F" "$NONCE" >/dev/null 2>&1
[[ $? -eq 10 ]] && pass "tool_result records around the injection are not preemption" \
  || fail "tool_result records around the injection are not preemption" "got exit $?"
rm -f "$F"

echo ""
echo "transcript-extract: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
