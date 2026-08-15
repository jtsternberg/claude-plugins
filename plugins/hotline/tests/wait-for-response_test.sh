#!/usr/bin/env bash
# =============================================================================
# Regression test for wait-for-response.sh + the documented caller patterns.
#
# Feeds synthesized stream.jsonl files through headless-call-async.sh's
# extraction logic, verifies response.json is valid JSON, and confirms that
# the hardened caller patterns (file-direct read and here-string) survive
# under zsh — which is where the original bug (claude-plugins-82u) surfaced.
#
# Runs without invoking real `claude -p`. Should finish in a few seconds.
#
# Usage: bash plugins/hotline/tests/wait-for-response_test.sh
# Exit 0 on success; exit 1 with failing case names on any failure.
# =============================================================================
set -u

# Collapse the poller's real sleep. wait-for-response.sh accounts its timeout
# budget in fixed 2s ticks and sleeps HOTLINE_POLL_SLEEP per tick, so this runs
# every loop the same number of iterations, down the same branches, to the same
# messages — for none of the wall-clock. Without it this suite spent ~2 minutes
# sleeping out real backoff intervals and dominated the whole repo's test time.
# Patience is therefore asserted on WHICH exit path ran (and on poll counts),
# never on wall-clock; the one case that must see the shipped cadence runs with
# `env -u HOTLINE_POLL_SLEEP`. (claude-plugins-fhn3)
export HOTLINE_POLL_SLEEP=0.02

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAL_SCRIPTS="$SCRIPT_DIR/../skills/dial/scripts"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/jq-parse-error-zsh-echo"

PASS=0
FAIL=0
FAILED_CASES=()

have_zsh=1
command -v zsh >/dev/null 2>&1 || have_zsh=0

# ---- helpers ---------------------------------------------------------------

# Reproduce the extraction logic from headless-call-async.sh against a
# synthesized stream.jsonl, writing response.json into CALL_DIR.
#
# This mirrors lines 118-150 of headless-call-async.sh so we can exercise
# the emission logic without spawning claude -p.
synthesize_response() {
  local call_dir="$1"
  local stream_file="$call_dir/stream.jsonl"

  if [[ ! -s "$stream_file" ]]; then
    echo "Synthetic stream file empty" > "$call_dir/error.txt"
    touch "$call_dir/done"
    return
  fi

  local result_line session_id response num_turns
  result_line=$(grep '"type":"result"' "$stream_file" 2>/dev/null | tail -1 || true)

  if [[ -z "$result_line" ]]; then
    echo "Stream had data but no result event" > "$call_dir/error.txt"
    touch "$call_dir/done"
    return
  fi

  session_id=$(echo "$result_line" | jq -r '.session_id // empty')
  response=$(echo "$result_line" | jq -r '.result // empty')

  if [[ -z "$response" ]]; then
    response=$(grep '"type":"assistant"' "$stream_file" \
      | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null \
      | tail -1 || true)
  fi

  if [[ -z "$response" ]]; then
    num_turns=$(echo "$result_line" | jq -r '.num_turns // 0')
    response="[HOTLINE WARNING: Agent ran $num_turns turns but produced no text response. Session ID: $session_id]"
  fi

  jq -n --arg sid "$session_id" --arg resp "$response" \
    '{session_id: $sid, response: $resp}' > "$call_dir/response.json"
  touch "$call_dir/done"
}

pass() {
  PASS=$((PASS + 1))
  echo "  ✓ $1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$1")
  echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

# Run one test case. Takes a name, a stream.jsonl body, and an expected
# response substring (or empty to skip content check).
run_case() {
  local name="$1"
  local stream_body="$2"
  local expected_substring="$3"

  local call_dir
  call_dir=$(mktemp -d /tmp/hotline-test-XXXXX)
  printf '%s' "$stream_body" > "$call_dir/stream.jsonl"
  synthesize_response "$call_dir"

  # 1. response.json must be valid JSON
  if ! jq -e . "$call_dir/response.json" >/dev/null 2>&1; then
    fail "$name (response.json not valid JSON)"
    rm -rf "$call_dir"
    return
  fi

  # 2. wait-for-response.sh must exit 0 with valid JSON on stdout
  local out
  if ! out=$(bash "$DIAL_SCRIPTS/wait-for-response.sh" "$call_dir" 2>&1); then
    fail "$name (wait-for-response.sh exited non-zero)" "$out"
    rm -rf "$call_dir"
    return
  fi
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    fail "$name (wait-for-response.sh stdout not valid JSON)"
    rm -rf "$call_dir"
    return
  fi

  # 3. If a substring was given, decoded .response must contain it
  if [[ -n "$expected_substring" ]]; then
    local decoded
    decoded=$(jq -r '.response' "$call_dir/response.json")
    if [[ "$decoded" != *"$expected_substring"* ]]; then
      fail "$name (expected substring not in decoded response)" "got: $(printf '%s' "$decoded" | head -c 120)"
      rm -rf "$call_dir"
      return
    fi
  fi

  pass "$name"
  rm -rf "$call_dir"
}

# ---- test cases ------------------------------------------------------------

echo "Test matrix:"

# 1. Normal multi-paragraph response with real newlines
run_case "multi-paragraph response with \\n escapes" \
  '{"type":"result","session_id":"s1","result":"Paragraph 1.\n\nParagraph 2.\n\nParagraph 3.","num_turns":1}
' \
  "Paragraph 2."

# 2. Fenced code block with backticks, pipes, quotes
run_case "fenced code block with backticks and quotes" \
  '{"type":"result","session_id":"s2","result":"```bash\necho \"hi\" | jq -r .x\n```","num_turns":1}
' \
  'jq -r'

# 3. Form-feed (0x0C) as \u000c in the result string
run_case "form-feed control byte (\\u000c)" \
  '{"type":"result","session_id":"s3","result":"before\u000cafter","num_turns":1}
' \
  "before"

# 4. Vertical-tab (0x0B) as \u000b
run_case "vertical-tab control byte (\\u000b)" \
  '{"type":"result","session_id":"s4","result":"before\u000bafter","num_turns":1}
' \
  "before"

# 5. ANSI escape sequence (0x1B) — common when the remote prints colored output
run_case "ANSI escape sequence (\\u001b)" \
  '{"type":"result","session_id":"s5","result":"\u001b[31mred\u001b[0m normal","num_turns":1}
' \
  "red"

# 6. Non-ASCII UTF-8: em dashes, smart quotes, emoji
run_case "non-ASCII UTF-8 (em dash, smart quote, emoji)" \
  '{"type":"result","session_id":"s6","result":"Hello — “world” 🎉","num_turns":1}
' \
  "world"

# 7. Empty .result, fallback to last assistant text
run_case "empty .result falls back to last assistant text" \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"early chatter"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"final text"}]}}
{"type":"result","session_id":"s7","result":"","num_turns":2}
' \
  "final text"

# 8. Zero assistant events, empty .result → HOTLINE WARNING placeholder
run_case "no assistant events, empty result → warning placeholder" \
  '{"type":"system","session_id":"s8"}
{"type":"result","session_id":"s8","result":"","num_turns":0}
' \
  "HOTLINE WARNING"

# 9. NUL byte as \u0000 — may or may not survive the extraction, but
#    whatever happens must produce either valid JSON or a loud non-zero exit.
#    (Shell variables cannot hold NUL, so the extraction silently drops it;
#    the important invariant is that stdout remains valid JSON.)
run_case "NUL byte (\\u0000) must not produce invalid JSON" \
  '{"type":"result","session_id":"s9","result":"before\u0000after","num_turns":1}
' \
  ""

# ---- caller-pattern cases --------------------------------------------------

echo ""
echo "Caller pattern regression (zsh-safe):"

run_caller_case() {
  local name="$1"
  local shell="$2"
  local snippet="$3"
  local expected_substring="$4"

  # Build a call_dir from the committed fixture
  local call_dir
  call_dir=$(mktemp -d /tmp/hotline-caller-XXXXX)
  cp "$FIXTURE_DIR/response.json" "$call_dir/response.json"
  touch "$call_dir/done"

  local cmd
  cmd="CALL_DIR='$call_dir'; DIAL_SCRIPTS='$DIAL_SCRIPTS'; $snippet"

  local out status
  out=$("$shell" -c "$cmd" 2>&1) || status=$?
  status=${status:-0}

  if [[ $status -ne 0 ]]; then
    fail "$name (exit $status)" "$out"
  elif [[ "$out" != *"$expected_substring"* ]]; then
    fail "$name (missing expected substring)" "got: $(printf '%s' "$out" | head -c 120)"
  else
    pass "$name"
  fi

  rm -rf "$call_dir"
}

# Safe pattern: read from the file directly (shell-agnostic)
run_caller_case "bash: read response.json from call_dir" bash \
  'bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CALL_DIR" >/dev/null && jq -r .response "$CALL_DIR/response.json"' \
  "multi-paragraph"

if [[ $have_zsh -eq 1 ]]; then
  run_caller_case "zsh: read response.json from call_dir" zsh \
    'bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CALL_DIR" >/dev/null && jq -r .response "$CALL_DIR/response.json"' \
    "multi-paragraph"

  # Safe pattern: here-string <<<"$VAR" preserves raw bytes
  run_caller_case "zsh: here-string <<<\"\$VAR\" preserves JSON" zsh \
    'RESPONSE_JSON=$(bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CALL_DIR"); jq -r .response <<<"$RESPONSE_JSON"' \
    "multi-paragraph"

  # Unsafe pattern: echo pipe — must NOT be documented as the caller pattern.
  # We expect this to fail; if it stops failing (e.g., because emitter swaps
  # to a form without backslash escapes), update SKILL.md accordingly.
  #
  # Pass paths via env so the zsh script body can stay single-quoted (no
  # shell-meta interpolation at bash-parse time) and survives paths with
  # spaces, quotes, or other shell-special characters.
  out=$(FIXTURE_DIR="$FIXTURE_DIR" DIAL_SCRIPTS="$DIAL_SCRIPTS" zsh -c '
    FIX_DIR=$(mktemp -d /tmp/hotline-unsafe-XXXXX)
    cp "$FIXTURE_DIR/response.json" "$FIX_DIR/response.json"
    touch "$FIX_DIR/done"
    RESPONSE_JSON=$(bash "$DIAL_SCRIPTS/wait-for-response.sh" "$FIX_DIR")
    echo "$RESPONSE_JSON" | jq -r .response 2>&1
    rm -rf "$FIX_DIR"
  ')
  if echo "$out" | grep -q "parse error"; then
    pass "zsh: \`echo \$VAR | jq\` correctly fails (documented as unsafe)"
  else
    fail "zsh: \`echo \$VAR | jq\` unexpectedly did NOT fail — SKILL.md may need re-audit" "$out"
  fi
else
  echo "  - zsh not found; skipping zsh-specific caller cases"
fi

# ---- CMUX transcript mode (claude-plugins-0pwc) ----------------------------
# wait-for-response.sh should prefer the callee's JSONL transcript over screen-
# scraping. We sandbox HOME so the derived ~/.claude/projects path lands in a
# temp tree, and stub `cmux` to a no-op (transcript success path makes no cmux
# calls when keep_workspace=true, but CMUX mode still resolves the surface ref).
echo ""
echo "CMUX transcript mode:"

TNONCE="testnonce0pwc01"
setup_transcript_call() {  # $1 = transcript body (JSONL); echoes "HOME|CALL_DIR|STUBDIR"
  local body="$1"
  local h cd sd cwd enc
  h=$(mktemp -d); cd=$(mktemp -d /tmp/hotline-tcm-XXXXX); sd=$(mktemp -d)
  cwd="/fake/callee/ws"
  enc=$(printf '%s' "$cwd" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$h/.claude/projects/$enc"
  printf '%s\n' "$body" > "$h/.claude/projects/$enc/sess-tcm.jsonl"
  echo "$cwd"      > "$cd/cwd.txt"
  echo "sess-tcm"  > "$cd/session_id.txt"
  echo "$TNONCE"   > "$cd/call_id.txt"
  echo "w1:s1"     > "$cd/surface_ref.txt"
  echo "true"      > "$cd/keep_workspace.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sd/cmux"; chmod +x "$sd/cmux"
  echo "$h|$cd|$sd"
}

# Complete turn in the transcript → transcript mode returns the response.
CT=$(setup_transcript_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"[CALL_ID: '"$TNONCE"'] hi"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$TNONCE"'\ntranscript-sourced answer\nSTATUS: DONE call_id='"$TNONCE"'"}]}}')
H1=${CT%%|*}; rest=${CT#*|}; CD1=${rest%%|*}; SD1=${rest#*|}
set +e
OUT1=$(HOME="$H1" PATH="$SD1:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD1" --timeout 20 --submit-deadline 6 2>/dev/null)
RC1=$?
set -e
if [[ $RC1 -eq 0 ]] && [[ "$(printf '%s' "$OUT1" | jq -r .response 2>/dev/null)" == *"transcript-sourced answer"* ]]; then
  pass "reads response from the JSONL transcript (no screen scrape)"
else
  fail "reads response from the JSONL transcript" "rc=$RC1 out=$OUT1"
fi
rm -rf "$H1" "$CD1" "$SD1"

# Transcript exists but no user event carries the nonce → fast-fail as
# never-submitted within the submit deadline (well under --timeout).
CT2=$(setup_transcript_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"unrelated chatter"}}')
H2=${CT2%%|*}; rest2=${CT2#*|}; CD2=${rest2%%|*}; SD2=${rest2#*|}
START=$SECONDS
set +e
ERR2=$(HOME="$H2" PATH="$SD2:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD2" --timeout 60 --submit-deadline 4 2>&1 >/dev/null)
RC2=$?
set -e
EL2=$((SECONDS - START))
# CONTRACT CHANGED (mo8m). This used to assert a fast-fail claiming "the message
# never submitted into the REPL". That cause is not observable from a timer: a
# follow-up sent while the callee is mid-turn is queued and its user event only
# lands when that turn ends, so the old assertion pinned a guess. This fixture's
# cmux stub is a bare `exit 0`, so read-screen yields nothing and the box check
# is inconclusive — the script must now stay patient and report uncertainty.
# The evidence-backed fast-fail is covered under "Submit discrimination" below.
if [[ $RC2 -ne 0 ]] && printf '%s' "$ERR2" | grep -qiE "could not confirm|no submit confirmation"; then
  pass "no nonce user event + unreadable screen → reports uncertainty, not a cause (${EL2}s)"
else
  fail "no nonce user event + unreadable screen → reports uncertainty, not a cause" \
    "rc=$RC2 elapsed=${EL2}s err=$ERR2"
fi
if printf '%s' "$ERR2" | grep -qiE "the message never submitted|never submitted into the REPL"; then
  fail "no longer asserts the unobservable 'never submitted' cause" "err=$ERR2"
else
  pass "no longer asserts the unobservable 'never submitted' cause"
fi
rm -rf "$H2" "$CD2" "$SD2"

# ---- preemption: the receiver was handed a different task (claude-plugins-dvjo)
# A visible surface is one the human can type into — that is the point of
# side-by-side placement. When they do, the receiver never emits OUR nonce's
# STATUS, and before this the caller sat through the full 1800s cmux timeout with
# no way to tell "still working" from "will never answer". Observed for real:
# dotfiles session 84bab936 did the work, got reassigned, and the waiter had to be
# killed by hand.
echo ""
echo "Preemption detection:"

# Preemption now lives in the extractor itself (one jq pass, not two) — exit 12.
PREEMPT_CHECK="$DIAL_SCRIPTS/transcript-extract.sh"

mk_transcript() {   # $1 = body → echoes path
  local d; d=$(mktemp -d)
  printf '%s\n' "$1" > "$d/t.jsonl"
  echo "$d/t.jsonl"
}

# Our prompt submitted, model still working, nobody else spoke → NOT preempted.
T_OK=$(mk_transcript \
'{"type":"user","sessionId":"s","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"working on it"}]}}')
set +e; bash "$PREEMPT_CHECK" "$T_OK" "$TNONCE" >/dev/null 2>&1; RCP=$?; set -e
if [[ $RCP -ne 12 ]]; then
  pass "a working receiver is not reported as preempted"
else
  fail "a working receiver is not reported as preempted" "rc=$RCP"
fi
rm -rf "$(dirname "$T_OK")"

# A human prompt after ours → preempted, and the prompt is reported.
T_PRE=$(mk_transcript \
'{"type":"user","sessionId":"s","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"on it"}]}}
{"type":"user","sessionId":"s","message":{"content":"actually go do the PSR4 migration instead"}}')
set +e; OUTP=$(bash "$PREEMPT_CHECK" "$T_PRE" "$TNONCE" 2>/dev/null); RCP=$?; set -e
if [[ $RCP -eq 12 ]] && printf '%s' "$OUTP" | grep -q "PSR4 migration"; then
  pass "a human prompt after ours is reported as preemption"
else
  fail "a human prompt after ours is reported as preemption" "rc=$RCP out=$OUTP"
fi
rm -rf "$(dirname "$T_PRE")"

# Tool results, meta records and subagent turns are NOT preemption.
T_NOISE=$(mk_transcript \
'{"type":"user","sessionId":"s","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"user","sessionId":"s","message":{"content":[{"type":"tool_result","tool_use_id":"t0","content":"file1"}]}}
{"type":"user","isMeta":true,"sessionId":"s","message":{"content":"injected context"}}
{"type":"user","isSidechain":true,"sessionId":"s","message":{"content":"subagent prompt"}}
{"type":"user","isCompactSummary":true,"sessionId":"s","message":{"content":"Summary: things"}}')
set +e; bash "$PREEMPT_CHECK" "$T_NOISE" "$TNONCE" >/dev/null 2>&1; RCP=$?; set -e
if [[ $RCP -ne 12 ]]; then
  pass "tool results, meta, subagent and compaction records are not preemption"
else
  fail "tool results, meta, subagent and compaction records are not preemption" "rc=$RCP"
fi
rm -rf "$(dirname "$T_NOISE")"

# A user interrupt is preemption too — the receiver will never finish our turn.
T_INT=$(mk_transcript \
'{"type":"user","sessionId":"s","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"user","sessionId":"s","message":{"content":"[Request interrupted by user for tool use]"}}')
set +e; bash "$PREEMPT_CHECK" "$T_INT" "$TNONCE" >/dev/null 2>&1; RCP=$?; set -e
if [[ $RCP -eq 12 ]]; then
  pass "a user interrupt counts as preemption"
else
  fail "a user interrupt counts as preemption" "rc=$RCP"
fi
rm -rf "$(dirname "$T_INT")"

# Our own prompt before the nonce turn must not count (no false positive on the
# ringing prompt or a prior call in the same session).
T_PRIOR=$(mk_transcript \
'{"type":"user","sessionId":"s","message":{"content":"an earlier unrelated human prompt"}}
{"type":"user","sessionId":"s","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"working"}]}}')
set +e; bash "$PREEMPT_CHECK" "$T_PRIOR" "$TNONCE" >/dev/null 2>&1; RCP=$?; set -e
if [[ $RCP -ne 12 ]]; then
  pass "prompts BEFORE our nonce turn are not preemption"
else
  fail "prompts BEFORE our nonce turn are not preemption" "rc=$RCP"
fi
rm -rf "$(dirname "$T_PRIOR")"

# Answered, THEN reassigned → the response is still owed to us. Preemption must
# never outrank a terminal STATUS that already arrived, or a caller loses a reply
# it had already earned.
T_DONE_THEN=$(mk_transcript \
'{"type":"user","sessionId":"s","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"here is the answer\nSTATUS: DONE call_id='"$TNONCE"'"}]}}
{"type":"user","sessionId":"s","message":{"content":"now go do something completely different"}}')
set +e; OUTD=$(bash "$PREEMPT_CHECK" "$T_DONE_THEN" "$TNONCE" 2>/dev/null); RCD=$?; set -e
if [[ $RCD -eq 0 ]] && printf '%s' "$OUTD" | jq -r .response 2>/dev/null | grep -q "here is the answer"; then
  pass "a completed answer still wins when the receiver is reassigned afterwards"
else
  fail "a completed answer still wins when reassigned afterwards" "rc=$RCD out=$OUTD"
fi
rm -rf "$(dirname "$T_DONE_THEN")"

# End to end: wait-for-response.sh must bail fast with exit 3, not sit out the timeout.
CT3=$(setup_transcript_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"[CALL_ID: '"$TNONCE"'] do the thing"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"content":[{"type":"text","text":"on it"}]}}
{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"never mind, do something else entirely"}}')
H3=${CT3%%|*}; rest3=${CT3#*|}; CD3=${rest3%%|*}; SD3=${rest3#*|}
START3=$SECONDS
set +e
ERR3=$(HOME="$H3" PATH="$SD3:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD3" --timeout 90 --submit-deadline 6 2>&1 >/dev/null)
RC3=$?
set -e
EL3=$((SECONDS - START3))
if [[ $RC3 -eq 3 && $EL3 -lt 30 ]] && printf '%s' "$ERR3" | grep -qi "reassigned\|preempt"; then
  pass "wait-for-response exits 3 on preemption instead of waiting out the timeout (${EL3}s)"
else
  fail "wait-for-response exits 3 on preemption" "rc=$RC3 elapsed=${EL3}s err=$ERR3"
fi
rm -rf "$H3" "$CD3" "$SD3"

# ---- submit discrimination (claude-plugins-mo8m) ---------------------------
# The submit deadline expiring is NOT evidence the message never submitted. A
# follow-up sent to a REPL that is mid-turn is queued, and its user event only
# lands when that turn ends — measured at 3.1-4.2s for short turns, and bounded
# only by the callee's current turn in principle. So a bare timer cannot tell
# "never submitted" from "submitted, still queued".
#
# What CAN tell them apart is the input box. If no user event carries the nonce
# and the nonce is nonetheless visible on the callee's screen, the text is
# sitting unsubmitted in the prompt box — that is real evidence. If it is not
# visible, we do not know, and must not assert a cause.
echo ""
echo "Submit discrimination:"

# Same fixture shape as setup_transcript_call, but the cmux stub can render a
# screen and the surface ref is optional.
setup_discrim_call() {  # $1=transcript body  $2=screen text  $3=with_surface(true/false)
  local body="$1" screen="$2" with_surface="${3:-true}"
  local h cd sd cwd enc
  h=$(mktemp -d); cd=$(mktemp -d /tmp/hotline-disc-XXXXX); sd=$(mktemp -d)
  cwd="/fake/callee/ws"
  enc=$(printf '%s' "$cwd" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$h/.claude/projects/$enc"
  printf '%s\n' "$body" > "$h/.claude/projects/$enc/sess-tcm.jsonl"
  echo "$cwd"     > "$cd/cwd.txt"
  echo "sess-tcm" > "$cd/session_id.txt"
  echo "$TNONCE"  > "$cd/call_id.txt"
  echo "true"     > "$cd/keep_workspace.txt"
  [[ "$with_surface" == "true" ]] && echo "w1:s1" > "$cd/surface_ref.txt"
  # The stub logs every invocation to $sd/cmux.log so a test can count poll ticks
  # directly instead of inferring them from wall-clock (claude-plugins-fhn3).
  {
    echo '#!/usr/bin/env bash'
    echo "printf '%s\\n' \"\$*\" >> '$sd/cmux.log'"
    echo 'if [[ "$1" == "read-screen" ]]; then'
    printf '  cat <<%s\n' "'SCREENEOF'"
    printf '%s\n' "$screen"
    echo "SCREENEOF"
    echo '  exit 0'
    echo 'fi'
    echo 'exit 0'
  } > "$sd/cmux"
  chmod +x "$sd/cmux"
  : > "$sd/cmux.log"
  echo "$h|$cd|$sd"
}

# Same, but `cmux read-screen` fails outright (surface gone).
setup_discrim_call_broken_screen() {  # $1=transcript body
  local body="$1" h cd sd cwd enc
  h=$(mktemp -d); cd=$(mktemp -d /tmp/hotline-disc-XXXXX); sd=$(mktemp -d)
  cwd="/fake/callee/ws"
  enc=$(printf '%s' "$cwd" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$h/.claude/projects/$enc"
  printf '%s\n' "$body" > "$h/.claude/projects/$enc/sess-tcm.jsonl"
  echo "$cwd"     > "$cd/cwd.txt"
  echo "sess-tcm" > "$cd/session_id.txt"
  echo "$TNONCE"  > "$cd/call_id.txt"
  echo "true"     > "$cd/keep_workspace.txt"
  echo "w1:s1"    > "$cd/surface_ref.txt"
  {
    echo '#!/usr/bin/env bash'
    echo '[[ "$1" == "read-screen" ]] && { echo "Error: internal_error" >&2; exit 1; }'
    echo 'exit 0'
  } > "$sd/cmux"
  chmod +x "$sd/cmux"
  echo "$h|$cd|$sd"
}

NO_EVENT_BODY='{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"unrelated chatter"}}'

# CASE 1 — nonce visible in the input box, no user event: a real non-submit.
# The script has evidence, so it may fast-fail AND name the cause.
D1=$(setup_discrim_call "$NO_EVENT_BODY" \
"╭──────────────────────────────────────╮
│ > [CALL_ID: $TNONCE] do the thing    │
╰──────────────────────────────────────╯
  ? for shortcuts" true)
H4=${D1%%|*}; r4=${D1#*|}; CD4=${r4%%|*}; SD4=${r4#*|}
START4=$SECONDS
set +e
ERR4=$(HOME="$H4" PATH="$SD4:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD4" --timeout 60 --submit-deadline 4 2>&1 >/dev/null)
RC4=$?
set -e
EL4=$((SECONDS - START4))
if [[ $RC4 -ne 0 && $EL4 -lt 30 ]] && printf '%s' "$ERR4" | grep -qi "input box"; then
  pass "unsubmitted text visible in the box → fast-fail naming the real cause (${EL4}s)"
else
  fail "unsubmitted text visible in the box → fast-fail naming the real cause" \
    "rc=$RC4 elapsed=${EL4}s err=$ERR4"
fi
rm -rf "$H4" "$CD4" "$SD4"

# CASE 1b — the SAME non-submit, but the payload collapsed. CC renders any paste
# over ~800 chars or 3 lines as `[Pasted text #N +M lines]`, so a parked work order
# — which is most of them — puts nothing carrying the nonce on screen. Looking only
# for the nonce answers "not visible" here and the waiter then sits out its entire
# budget on a message that is never going to submit (claude-plugins-y4rl). The
# placeholder in the LIVE INPUT BOX is the same evidence and must fast-fail the same
# way. Real `❯` + U+00A0 box, because that is what input_box_content reads.
GLYPH=$'\xe2\x9d\xaf'; NBSP=$'\xc2\xa0'
D1B=$(setup_discrim_call "$NO_EVENT_BODY" \
"$GLYPH do the thing
────────────────────────────────────────
${GLYPH}${NBSP}[Pasted text #2 +18 lines]
────────────────────────────────────────
  ? for shortcuts" true)
H4B=${D1B%%|*}; r4b=${D1B#*|}; CD4B=${r4b%%|*}; SD4B=${r4b#*|}
START4B=$SECONDS
set +e
ERR4B=$(HOME="$H4B" PATH="$SD4B:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD4B" --timeout 60 --submit-deadline 4 2>&1 >/dev/null)
RC4B=$?
set -e
EL4B=$((SECONDS - START4B))
# Asserted on the MESSAGE, not on wall-clock or a bare "input box" grep: the sleeps
# are collapsed (claude-plugins-fhn3) and the patient 60s-timeout message ALSO names
# the input box, as the recovery step to try. Only the fast-fail branch says the
# payload is sitting there — so that string is the one thing that separates
# "detected and reported" from "waited out the whole budget", which is the bug.
if [[ $RC4B -ne 0 ]] && printf '%s' "$ERR4B" | grep -q "still sitting UNSUBMITTED in the callee's input box"; then
  pass "collapsed placeholder parked in the box → fast-fail naming the real cause (${EL4B}s)"
else
  fail "collapsed placeholder parked in the box → fast-fail naming the real cause" \
    "rc=$RC4B elapsed=${EL4B}s err=$ERR4B"
fi
# And it says what it actually saw. Claiming the nonce is visible when a placeholder
# is hiding it sends the reader looking for text that is not there.
if printf '%s' "$ERR4B" | grep -qi "placeholder"; then
  pass "collapsed placeholder → the diagnostic reports the placeholder, not a visible nonce"
else
  fail "collapsed placeholder → the diagnostic reports the placeholder, not a visible nonce" \
    "err=$ERR4B"
fi
# The waiter must never submit for the callee: an extra Enter on a payload that DID
# submit is a double submit, and it cannot tell the two apart.
if grep -qi 'send-key\|send ' "$SD4B/cmux.log" 2>/dev/null; then
  fail "collapsed placeholder → the waiter must not press Enter" "log=$(cat "$SD4B/cmux.log")"
else
  pass "collapsed placeholder → the waiter reports and sends nothing"
fi
rm -rf "$H4B" "$CD4B" "$SD4B"

# CASE 2 — nonce NOT on screen, no user event: indistinguishable from a queued
# submit behind a long turn. The script must NOT claim it never submitted, and
# must NOT give up at the submit deadline — it stays patient until --timeout.
D2=$(setup_discrim_call "$NO_EVENT_BODY" \
"╭──────────────────────────────────────╮
│ >                                    │
╰──────────────────────────────────────╯
  ? for shortcuts" true)
H5=${D2%%|*}; r5=${D2#*|}; CD5=${r5%%|*}; SD5=${r5#*|}
set +e
ERR5=$(HOME="$H5" PATH="$SD5:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD5" --timeout 12 --submit-deadline 4 2>&1 >/dev/null)
RC5=$?
set -e
# Match the ASSERTIVE claim, not the words — the correct hedge legitimately
# contains "may never have submitted", which a naive grep would flag.
if printf '%s' "$ERR5" | grep -qiE "the message never submitted|never submitted into the REPL"; then
  fail "empty box → must not assert 'never submitted'" "err=$ERR5"
else
  pass "empty box → does not assert 'never submitted'"
fi
# Patience is asserted on BUDGET, not wall-clock, because the sleeps are collapsed
# (claude-plugins-fhn3). Giving up at the 4s submit deadline leaves via the
# input-box branch with a different message; only consuming the whole 12s budget
# reaches "Timed out after 12s". Both exits are rc 1, so the message IS the
# discriminator — a stricter test than a stopwatch, which only saw duration.
if [[ $RC5 -ne 0 ]] && printf '%s' "$ERR5" | grep -q "Timed out after 12s in transcript mode"; then
  pass "empty box → spends the whole 12s budget, not just the submit deadline"
else
  fail "empty box → spends the whole 12s budget, not just the submit deadline" \
    "rc=$RC5 err=$ERR5"
fi
# Independent proof it really iterated: one box check per tick from the 4s deadline
# to the 12s budget (ticks at 4, 6, 8, 10).
BOX_CHECKS=0
[[ -f "$SD5/cmux.log" ]] && BOX_CHECKS=$(grep -c "read-screen" "$SD5/cmux.log" || true)
if [[ ${BOX_CHECKS:-0} -ge 3 ]]; then
  pass "empty box → re-checks the input box on every tick past the deadline (${BOX_CHECKS}x)"
else
  fail "empty box → re-checks the input box on every tick past the deadline" \
    "only ${BOX_CHECKS} read-screen calls with a 4s deadline and a 12s budget; rc=$RC5"
fi

# CASE 3 — the surface ref exists but read-screen FAILS (surface died between
# the send and now), so the discriminator is unavailable. Transcript mode only
# runs in CMUX mode, which requires a surface/workspace ref — a call_dir with no
# ref is headless and never reaches the submit deadline at all, so an unreadable
# surface is the real "cannot discriminate" case, not a missing one.
D3=$(setup_discrim_call_broken_screen "$NO_EVENT_BODY")
H6=${D3%%|*}; r6=${D3#*|}; CD6=${r6%%|*}; SD6=${r6#*|}
set +e
ERR6=$(HOME="$H6" PATH="$SD6:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD6" --timeout 12 --submit-deadline 4 2>&1 >/dev/null)
RC6=$?
set -e
if printf '%s' "$ERR6" | grep -qiE "the message never submitted|never submitted into the REPL"; then
  fail "unreadable surface → must not assert 'never submitted'" "err=$ERR6"
else
  pass "unreadable surface → does not assert 'never submitted'"
fi
if printf '%s' "$ERR6" | grep -qiE "could not confirm|no submit confirmation|may (still )?be"; then
  pass "unreadable surface → reports the uncertainty instead of a cause"
else
  fail "unreadable surface → reports the uncertainty instead of a cause" "err=$ERR6"
fi
rm -rf "$H5" "$CD5" "$SD5" "$H6" "$CD6" "$SD6"

# ---- queued follow-ups (claude-plugins-1jpz) -------------------------------
# A follow-up sent while the callee is mid-turn is ENQUEUED, and claude delivers
# it one of two ways: (a) injected into the SAME turn at the next tool boundary
# as an `attachment` record of type "queued_command" — no user record is EVER
# written, yet the model answers it; or (b) flushed after turn end as a genuine
# user record. Correlating on user records only made path (a) look like a
# never-submitted message the receiver had already answered.
echo ""
echo "Queued follow-up delivery:"

# Record shapes copied from a live 2.1.221 transcript.
Q_ENQ='{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-04T22:14:36.125Z","sessionId":"sess-tcm","content":"[CALL_ID: '"$TNONCE"'] do the thing"}'
Q_ATT='{"parentUuid":"cf341cc5-f248-4a10-abee-e89efca05220","isSidechain":false,"attachment":{"type":"queued_command","prompt":"[CALL_ID: '"$TNONCE"'] do the thing","commandMode":"prompt","origin":{"kind":"human"},"timestamp":"2026-08-04T22:14:36.125Z"},"type":"attachment","uuid":"7b3e5d13-7ca1-4f8b-8be2-99bc9d5f5f64","timestamp":"2026-08-04T22:14:36.125Z","sessionId":"sess-tcm","version":"2.1.221","gitBranch":"HEAD"}'

# CASE 4 — path (a) end to end: the answer must come back on exit 0, promptly,
# with no user record anywhere in the transcript.
CT4=$(setup_transcript_call \
"$Q_ENQ
$Q_ATT
{\"type\":\"assistant\",\"isSidechain\":false,\"sessionId\":\"sess-tcm\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"STATUS: WORK_IN_PROGRESS call_id=$TNONCE\nqueued-injection answer\nSTATUS: DONE call_id=$TNONCE\"}]}}")
H7=${CT4%%|*}; r7=${CT4#*|}; CD7=${r7%%|*}; SD7=${r7#*|}
START7=$SECONDS
set +e
OUT7=$(HOME="$H7" PATH="$SD7:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD7" --timeout 20 --submit-deadline 4 2>/dev/null)
RC7=$?
set -e
EL7=$((SECONDS - START7))
if [[ $RC7 -eq 0 && $EL7 -lt 15 ]] && [[ "$(printf '%s' "$OUT7" | jq -r .response 2>/dev/null)" == *"queued-injection answer"* ]]; then
  pass "mid-turn injection with no user record → returns the answer (${EL7}s)"
else
  fail "mid-turn injection with no user record → returns the answer" "rc=$RC7 elapsed=${EL7}s out=$OUT7"
fi
rm -rf "$H7" "$CD7" "$SD7"

# CASE 5 — a queued message is RENDERED on the callee's screen while it waits,
# so the input-box discriminator would call it "unsubmitted" if the enqueue
# record didn't already prove otherwise. It must stay patient and never blame
# the transport.
D4=$(setup_discrim_call "$Q_ENQ" \
"╭──────────────────────────────────────╮
│ >                                    │
╰──────────────────────────────────────╯
  ⏵⏵ queued: [CALL_ID: $TNONCE] do the thing" true)
H8=${D4%%|*}; r8=${D4#*|}; CD8=${r8%%|*}; SD8=${r8#*|}
set +e
ERR8=$(HOME="$H8" PATH="$SD8:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD8" --timeout 12 --submit-deadline 4 2>&1 >/dev/null)
RC8=$?
set -e
if printf '%s' "$ERR8" | grep -qi "input box"; then
  fail "queued-and-visible → must not be blamed on the input box" "err=$ERR8"
else
  pass "queued-and-visible → not blamed on the input box"
fi
# The enqueue record marks it submitted, so this must reach the plain
# "callee is slower than the budget" timeout — the full 12s, patiently.
if [[ $RC8 -ne 0 ]] && printf '%s' "$ERR8" | grep -q "transcript mode, 12s"; then
  pass "queued-and-visible → spends the whole 12s budget as submitted work"
else
  fail "queued-and-visible → spends the whole 12s budget as submitted work" \
    "rc=$RC8 err=$ERR8"
fi
rm -rf "$H8" "$CD8" "$SD8"

# ---- AWAITING_REVIEW (claude-plugins-n4vy) ---------------------------------
# A checkpointed work order — do step 1, report, hold for the lead's review — had
# no honest terminal STATUS. WORK_IN_PROGRESS was the only truthful thing to emit
# ("the work order is not finished"), and that is exactly what this script treats
# as "keep polling", so the waiter blocked past its 600s tool timeout while the
# callee's finished report sat complete in its transcript and had to be scraped by
# hand. AWAITING_REVIEW returns the body like a terminal status does, but on
# exit 4 and with `awaiting_review: true` in the JSON — and it must NEVER close
# the surface, because the whole point is that a follow-up is coming.
echo ""
echo "AWAITING_REVIEW checkpoint:"

# Same shape as setup_transcript_call, but keep_workspace=false and the cmux stub
# logs every invocation, so we can prove the live surface was left alone.
setup_await_call() {  # $1 = transcript body → echoes "HOME|CALL_DIR|STUBDIR|LOG"
  local body="$1" h cd sd cwd enc log
  h=$(mktemp -d); cd=$(mktemp -d /tmp/hotline-await-XXXXX); sd=$(mktemp -d)
  log="$sd/cmux.log"
  cwd="/fake/callee/ws"
  enc=$(printf '%s' "$cwd" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$h/.claude/projects/$enc"
  printf '%s\n' "$body" > "$h/.claude/projects/$enc/sess-tcm.jsonl"
  echo "$cwd"     > "$cd/cwd.txt"
  echo "sess-tcm" > "$cd/session_id.txt"
  echo "$TNONCE"  > "$cd/call_id.txt"
  echo "w1:s1"    > "$cd/surface_ref.txt"
  echo "false"    > "$cd/keep_workspace.txt"   # would normally close the surface
  {
    echo '#!/usr/bin/env bash'
    echo "printf '%s\\n' \"\$*\" >> '$log'"
    echo 'exit 0'
  } > "$sd/cmux"
  chmod +x "$sd/cmux"
  : > "$log"
  echo "$h|$cd|$sd|$log"
}

AW=$(setup_await_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"[CALL_ID: '"$TNONCE"'] task 1 of 3, report and hold"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$TNONCE"'\ntask 1 done, holding for review\nSTATUS: AWAITING_REVIEW call_id='"$TNONCE"'"}]}}')
H9=${AW%%|*}; r9=${AW#*|}; CD9=${r9%%|*}; r9b=${r9#*|}; SD9=${r9b%%|*}; LOG9=${r9b#*|}
START9=$SECONDS
set +e
OUT9=$(HOME="$H9" PATH="$SD9:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD9" --timeout 40 --submit-deadline 6 2>/dev/null)
RC9=$?
set -e
EL9=$((SECONDS - START9))
if [[ $RC9 -eq 4 && $EL9 -lt 20 ]]; then
  pass "AWAITING_REVIEW returns instead of polling, exit 4 (${EL9}s)"
else
  fail "AWAITING_REVIEW returns instead of polling, exit 4" "rc=$RC9 elapsed=${EL9}s out=$OUT9"
fi
if [[ "$(printf '%s' "$OUT9" | jq -r .response 2>/dev/null)" == *"holding for review"* ]]; then
  pass "AWAITING_REVIEW delivers the response body like a terminal status"
else
  fail "AWAITING_REVIEW delivers the response body" "out=$OUT9"
fi
if [[ "$(printf '%s' "$OUT9" | jq -r '.awaiting_review // false' 2>/dev/null)" == "true" ]]; then
  pass "stdout JSON carries awaiting_review:true"
else
  fail "stdout JSON carries awaiting_review:true" "out=$OUT9"
fi
if [[ "$(jq -r '.awaiting_review // false' "$CD9/response.json" 2>/dev/null)" == "true" ]]; then
  pass "response.json carries awaiting_review:true for a file-reading caller"
else
  fail "response.json carries awaiting_review:true" "$(cat "$CD9/response.json" 2>/dev/null)"
fi
if grep -qE "close-surface|close-workspace" "$LOG9" 2>/dev/null; then
  fail "AWAITING_REVIEW must leave the surface live for the follow-up" "cmux calls: $(cat "$LOG9")"
else
  pass "AWAITING_REVIEW leaves the surface live even with keep_workspace=false"
fi
rm -rf "$H9" "$CD9" "$SD9"

# WORK_IN_PROGRESS semantics unchanged: a WIP-only transcript is still "keep
# polling", so the waiter must sit out the timeout rather than resolving early.
AW2=$(setup_await_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"[CALL_ID: '"$TNONCE"'] task 1 of 3"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$TNONCE"'\nstill grinding"}]}}')
HA=${AW2%%|*}; rA=${AW2#*|}; CDA=${rA%%|*}; rAb=${rA#*|}; SDA=${rAb%%|*}; LOGA=${rAb#*|}
set +e
ERRA=$(HOME="$HA" PATH="$SDA:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CDA" --timeout 12 --submit-deadline 4 2>&1 >/dev/null)
RCA=$?
set -e
# Resolving early would exit 0 with a response; the only other way out is the
# 12s-budget timeout. So rc 1 plus that message is the whole claim.
if [[ $RCA -eq 1 ]] && printf '%s' "$ERRA" | grep -q "transcript mode, 12s"; then
  pass "WORK_IN_PROGRESS still means keep polling (whole 12s budget, then timeout)"
else
  fail "WORK_IN_PROGRESS still means keep polling" "rc=$RCA err=$ERRA"
fi
rm -rf "$HA" "$CDA" "$SDA"

# ---- resumable waiter timeout (claude-plugins-tyaj) ------------------------
# A waiter that runs out of budget writes done+error.txt so a caller who does not
# want to wait again sees the failure without re-polling. That made a long work
# order unwaitable: after the 1800s budget expired once, every re-invocation on the
# same call_dir replayed "Timed out" within seconds, so the caller could not resume
# the wait at all (hit live 2026-08-12; worked around with a hand-rolled monitor).
# A timeout now also drops waiter_timeout.txt, and finding it means "resume", not
# "this call failed".
echo ""
echo "Resuming after a waiter timeout:"

transcript_file_for() {  # $1 = sandboxed HOME → path setup_transcript_call wrote
  local enc; enc=$(printf '%s' "/fake/callee/ws" | sed 's|[^a-zA-Z0-9]|-|g')
  echo "$1/.claude/projects/$enc/sess-tcm.jsonl"
}

# A callee still working when the budget runs out.
RT=$(setup_transcript_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"[CALL_ID: '"$TNONCE"'] long work order"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$TNONCE"'\ngrinding"}]}}')
HB=${RT%%|*}; rB=${RT#*|}; CDB=${rB%%|*}; SDB=${rB#*|}
set +e
ERRB1=$(HOME="$HB" PATH="$SDB:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CDB" \
  --timeout 6 --submit-deadline 99 2>&1 >/dev/null)
RCB1=$?
set -e
if [[ $RCB1 -eq 1 && -f "$CDB/waiter_timeout.txt" ]]; then
  pass "an expired budget is recorded as resumable (waiter_timeout.txt)"
else
  fail "an expired budget is recorded as resumable" \
    "rc=$RCB1 files=$(ls "$CDB" | tr '\n' ' ') err=$ERRB1"
fi
if printf '%s' "$ERRB1" | grep -qi "fresh"; then
  pass "the timeout message tells the caller re-running resumes the wait"
else
  fail "the timeout message tells the caller re-running resumes the wait" "err=$ERRB1"
fi

# The callee finishes after the first waiter has already given up.
printf '%s\n' '{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$TNONCE"'\nlate but finished\nSTATUS: WORK_COMPLETE call_id='"$TNONCE"'"}]}}' \
  >> "$(transcript_file_for "$HB")"
set +e
OUTB2=$(HOME="$HB" PATH="$SDB:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CDB" \
  --timeout 6 --submit-deadline 99 2>"$SDB/err2.txt")
RCB2=$?
set -e
if [[ $RCB2 -eq 0 ]] && \
   [[ "$(printf '%s' "$OUTB2" | jq -r .response 2>/dev/null)" == *"late but finished"* ]]; then
  pass "re-invoking after a timeout opens a fresh window and returns the answer"
else
  fail "re-invoking after a timeout opens a fresh window and returns the answer" \
    "rc=$RCB2 out=$OUTB2 err=$(cat "$SDB/err2.txt" 2>/dev/null)"
fi
if grep -q "previous waiter gave up" "$SDB/err2.txt" 2>/dev/null; then
  pass "the resume is announced on stderr rather than silently swallowing the marker"
else
  fail "the resume is announced on stderr" "err=$(cat "$SDB/err2.txt" 2>/dev/null)"
fi
if [[ ! -f "$CDB/waiter_timeout.txt" ]]; then
  pass "the marker is cleared once the wait is resumed"
else
  fail "the marker is cleared once the wait is resumed"
fi
rm -rf "$HB" "$CDB" "$SDB"

# A real remote failure — done + error.txt and NO marker — must still short-circuit
# instantly and stay terminal. That fast path is what the marker exists to keep
# intact while making a mere timeout resumable.
TF=$(mktemp -d /tmp/hotline-term-XXXXX)
echo "w1:s1"            > "$TF/surface_ref.txt"
echo "true"             > "$TF/keep_workspace.txt"
echo "launcher blew up" > "$TF/error.txt"
touch "$TF/done"
set +e
ERRT=$(bash "$DIAL_SCRIPTS/wait-for-response.sh" "$TF" --timeout 6 2>&1 >/dev/null)
RCT=$?
set -e
if [[ $RCT -eq 1 ]] && printf '%s' "$ERRT" | grep -q "launcher blew up" \
   && [[ -f "$TF/done" && -f "$TF/error.txt" ]]; then
  pass "a remote failure with no marker still short-circuits and stays terminal"
else
  fail "a remote failure with no marker still short-circuits and stays terminal" \
    "rc=$RCT err=$ERRT"
fi
rm -rf "$TF"

# A stale marker must never discard a call that actually produced a response.
TG=$(mktemp -d /tmp/hotline-guard-XXXXX)
echo '{"session_id":"s-guard","response":"already answered"}' > "$TG/response.json"
printf 'budget=6s mode=transcript' > "$TG/waiter_timeout.txt"
touch "$TG/done"
set +e
OUTG=$(bash "$DIAL_SCRIPTS/wait-for-response.sh" "$TG" --timeout 6 2>/dev/null)
RCG=$?
set -e
if [[ $RCG -eq 0 ]] && [[ "$(printf '%s' "$OUTG" | jq -r .response 2>/dev/null)" == "already answered" ]]; then
  pass "a stale marker never discards a call that already produced response.json"
else
  fail "a stale marker never discards a call that already produced response.json" \
    "rc=$RCG out=$OUTG"
fi
rm -rf "$TG"

# ---- shipped poll cadence (claude-plugins-fhn3) ----------------------------
# Every other case in this file runs with HOTLINE_POLL_SLEEP collapsed, so nothing
# else here would notice if the DEFAULT were broken — and a 0 default would turn the
# production poller into a spin-loop hammering jq and cmux. This is the one case
# that runs the shipped cadence: a 4s budget is 2 ticks and must cost ~4s.
echo ""
echo "Shipped poll cadence (override unset):"

DC=$(setup_transcript_call \
'{"type":"user","isSidechain":false,"sessionId":"sess-tcm","message":{"content":"[CALL_ID: '"$TNONCE"'] work"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-tcm","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id='"$TNONCE"'\nworking"}]}}')
HC=${DC%%|*}; rC=${DC#*|}; CDC=${rC%%|*}; SDC=${rC#*|}
STARTC=$SECONDS
set +e
env -u HOTLINE_POLL_SLEEP HOME="$HC" PATH="$SDC:$PATH" \
  bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CDC" --timeout 4 --submit-deadline 99 \
  >/dev/null 2>&1
RCC=$?
set -e
ELC=$((SECONDS - STARTC))
if [[ $RCC -eq 1 && $ELC -ge 3 ]]; then
  pass "unset override → poller sleeps the shipped 2s per tick (${ELC}s for a 4s budget)"
else
  fail "unset override → poller sleeps the shipped 2s per tick" \
    "rc=$RCC elapsed=${ELC}s; a 4s budget should cost ~4s of wall-clock"
fi
rm -rf "$HC" "$CDC" "$SDC"

# ---- summary ---------------------------------------------------------------

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
