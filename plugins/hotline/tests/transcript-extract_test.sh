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

echo ""
echo "transcript-extract: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
