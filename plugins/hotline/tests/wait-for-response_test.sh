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
