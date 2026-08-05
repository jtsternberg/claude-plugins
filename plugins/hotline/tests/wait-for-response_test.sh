#!/usr/bin/env bash
# =============================================================================
# Regression test for wait-for-response.sh + the documented caller patterns.
#
# Feeds synthesized stream.jsonl files through headless-call-async.sh's
# extraction logic, verifies response.json is valid JSON, and confirms that
# the hardened caller patterns (file-direct read and here-string) survive
# under zsh — which is where the original bug (claude-plugins-82u) surfaced.
#
# Runs without invoking real `claude -p`. Should finish under 5 seconds.
#
# Usage: bash plugins/hotline/tests/wait-for-response_test.sh
# Exit 0 on success; exit 1 with failing case names on any failure.
# =============================================================================
set -u

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
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "read-screen" ]]; then'
    printf '  cat <<%s\n' "'SCREENEOF'"
    printf '%s\n' "$screen"
    echo "SCREENEOF"
    echo '  exit 0'
    echo 'fi'
    echo 'exit 0'
  } > "$sd/cmux"
  chmod +x "$sd/cmux"
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

# CASE 2 — nonce NOT on screen, no user event: indistinguishable from a queued
# submit behind a long turn. The script must NOT claim it never submitted, and
# must NOT give up at the submit deadline — it stays patient until --timeout.
D2=$(setup_discrim_call "$NO_EVENT_BODY" \
"╭──────────────────────────────────────╮
│ >                                    │
╰──────────────────────────────────────╯
  ? for shortcuts" true)
H5=${D2%%|*}; r5=${D2#*|}; CD5=${r5%%|*}; SD5=${r5#*|}
START5=$SECONDS
set +e
ERR5=$(HOME="$H5" PATH="$SD5:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD5" --timeout 12 --submit-deadline 4 2>&1 >/dev/null)
RC5=$?
set -e
EL5=$((SECONDS - START5))
# Match the ASSERTIVE claim, not the words — the correct hedge legitimately
# contains "may never have submitted", which a naive grep would flag.
if printf '%s' "$ERR5" | grep -qiE "the message never submitted|never submitted into the REPL"; then
  fail "empty box → must not assert 'never submitted'" "err=$ERR5"
else
  pass "empty box → does not assert 'never submitted'"
fi
if [[ $EL5 -ge 10 ]]; then
  pass "empty box → stays patient past the submit deadline (${EL5}s of 12s)"
else
  fail "empty box → stays patient past the submit deadline" \
    "gave up after ${EL5}s with a 4s submit-deadline and a 12s timeout; rc=$RC5 err=$ERR5"
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
START8=$SECONDS
set +e
ERR8=$(HOME="$H8" PATH="$SD8:$PATH" bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD8" --timeout 12 --submit-deadline 4 2>&1 >/dev/null)
RC8=$?
set -e
EL8=$((SECONDS - START8))
if printf '%s' "$ERR8" | grep -qi "input box"; then
  fail "queued-and-visible → must not be blamed on the input box" "err=$ERR8"
else
  pass "queued-and-visible → not blamed on the input box"
fi
if [[ $RC8 -ne 0 && $EL8 -ge 10 ]]; then
  pass "queued-and-visible → waits out the timeout as submitted work (${EL8}s of 12s)"
else
  fail "queued-and-visible → waits out the timeout as submitted work" \
    "rc=$RC8 elapsed=${EL8}s err=$ERR8"
fi
rm -rf "$H8" "$CD8" "$SD8"

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
