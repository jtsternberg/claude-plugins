#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-call-async.sh logic that can be exercised without
# launching cmux or Claude.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/cmux-call-async.sh"

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

build_launch_script() {
  local resume_id="$1"
  local session_id_preset="$2"
  local fork_session="$3"
  local session_name="$4"
  local allowed_tools="$5"
  local prompt="$6"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'claude'
    [[ -n "$resume_id" ]] && printf ' --resume %q' "$resume_id"
    [[ -z "$resume_id" && -n "$session_id_preset" ]] && \
      printf ' --session-id %q' "$session_id_preset"
    $fork_session && printf ' --fork-session'
    [[ -n "$session_name" ]] && printf ' -n %q' "$session_name"
    printf ' --allowedTools %q' "$allowed_tools"
    printf ' -- %q\n' "$prompt"
  }
}

# Latest STATUS line anywhere — mirrors the production poller. Robust against
# trailing terminal chrome (shell prompts, `│ > │` REPL prompt box bottoms)
# that would otherwise appear AFTER the real STATUS line.
latest_status() {
  awk '
    /^[[:space:]]*(⏺[[:space:]]+)?STATUS: / {
      line=$0
      sub(/^[[:space:]]*(⏺[[:space:]]+)?/, "", line)
      s=line
    }
    END {print s}
  '
}

# Response extraction — mirrors the production poller. Resets on every
# WORK_IN_PROGRESS, saves on every terminal STATUS, emits the LAST saved
# buffer so multi-terminal-status screens use the most recent body.
# Allows leading whitespace AND claude's `⏺ ` assistant-marker prefix
# on STATUS lines, because the REPL renders the FIRST line of an
# assistant response with `⏺ ` and subsequent lines with a 2-space
# indent — so a STATUS line can appear as any of:
#   "STATUS: DONE"
#   "  STATUS: DONE"
#   "⏺ STATUS: DONE"
extract_cmux_response() {
  grep -v "^bash /tmp/hotline-launch" \
    | grep -vE "^[╭│╰─└┌┘┐ℹ]" \
    | grep -vE "^>[[:space:]]*$" \
    | awk '
        /^[[:space:]]*(⏺[[:space:]]+)?STATUS: WORK_IN_PROGRESS[[:space:]]*$/ {buf=""; next}
        /^[[:space:]]*(⏺[[:space:]]+)?STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE)[[:space:]]*$/ {result=buf; buf=""; next}
        {buf = buf $0 ORS}
        END {printf "%s", result}
      '
}

assert_async_error_contract() {
  local label="$1"
  local tmp="$2"
  local output_file="$tmp/out.json"
  local stderr_file="$tmp/stderr.txt"

  local call_dir
  call_dir=$(jq -r '.call_dir // empty' "$output_file" 2>/dev/null || true)

  if [[ -z "$call_dir" || ! -d "$call_dir" ]]; then
    fail "$label returns a usable call_dir" "stdout=$(cat "$output_file" 2>/dev/null) stderr=$(cat "$stderr_file" 2>/dev/null)"
    return
  fi

  if [[ -f "$call_dir/done" && -f "$call_dir/error.txt" ]]; then
    pass "$label writes done and error.txt"
  else
    fail "$label writes done and error.txt" "call_dir=$call_dir"
  fi

  # Regression: session_id.txt must NOT exist on early-failure paths.
  # Writing it upfront (the old behavior) caused wait-for-session.sh to
  # report success even when claude never started.
  if [[ ! -f "$call_dir/session_id.txt" ]]; then
    pass "$label does not write a stale session_id.txt"
  else
    fail "$label does not write a stale session_id.txt" \
         "session_id.txt present: $(cat "$call_dir/session_id.txt" 2>/dev/null)"
  fi

  rm -rf "$call_dir"
}

echo "cmux-call-async regression:"

script=$(build_launch_script "" "11111111-1111-4111-8111-111111111111" false "hotline test" "Bash(git *) Edit" "hello")
if printf '%s' "$script" | bash -n 2> /tmp/hotline-cmux-test.err; then
  pass "launch script quotes complex --tools specs"
else
  fail "launch script quotes complex --tools specs" "$(cat /tmp/hotline-cmux-test.err)"
fi
rm -f /tmp/hotline-cmux-test.err

# Regression: --allowedTools is variadic (<tools...>). Without `--` separating
# the tools list from the positional prompt, claude swallows the prompt as
# another "tool" name and starts with an empty REPL ("No conversation yet").
# This was the actual root cause of the original lindris-frontend ↔
# lindris-backend hotline-call failure on 2026-05-14. Verified by reproducing
# the broken arg order live in a cmux workspace.
script=$(build_launch_script "" "22222222-2222-4222-8222-222222222222" false "name" "Bash Read" "submit me")
if printf '%s' "$script" | grep -qE -- "--allowedTools .+ -- "; then
  pass "launch script puts -- between --allowedTools and the positional prompt"
else
  fail "launch script puts -- between --allowedTools and the positional prompt" \
       "got: $script"
fi

screen=$'partial progress\nSTATUS: WORK_IN_PROGRESS\nfinal answer\nSTATUS: WORK_COMPLETE\n'
status=$(printf '%s' "$screen" | latest_status)
response=$(printf '%s' "$screen" | extract_cmux_response)

if [[ "$status" == "STATUS: WORK_COMPLETE" ]]; then
  pass "latest terminal status wins over earlier progress"
else
  fail "latest terminal status wins over earlier progress" "got: $status"
fi

if [[ "$response" == "final answer" ]]; then
  pass "response is taken after the last progress marker"
else
  fail "response is taken after the last progress marker" "got: $(printf '%q' "$response")"
fi

# Multi-terminal-status case: two terminal STATUS lines on the same screen.
# Can happen if the receiver retried a turn or the screen captured an earlier
# completion plus a later one. Both detection and extraction must use the LAST
# terminal status, not the first.
screen=$'first attempt body\nSTATUS: WORK_COMPLETE\n--- new turn ---\nsecond attempt body\nSTATUS: DONE\n'
status=$(printf '%s' "$screen" | latest_status)
response=$(printf '%s' "$screen" | extract_cmux_response)

if [[ "$status" == "STATUS: DONE" ]]; then
  pass "latest terminal status wins over an earlier terminal status"
else
  fail "latest terminal status wins over an earlier terminal status" "got: $status"
fi

if [[ "$response" == *"second attempt body"* && "$response" != *"first attempt body"* ]]; then
  pass "response uses body before LAST terminal status, not the first"
else
  fail "response uses body before LAST terminal status, not the first" \
       "got: $(printf '%q' "$response")"
fi

# Indented-STATUS case: claude's REPL renders response content with 2 spaces
# of indent inside the assistant bubble — the actual line on screen is
# "  STATUS: DONE", not "STATUS: DONE". A column-0 anchor regex would miss
# it. Verified live against a real receiver session.
screen=$'  ⏺ PR status report\n  body line one\n  body line two\n  STATUS: DONE\n'
status=$(printf '%s' "$screen" | latest_status)
if [[ "$status" == "STATUS: DONE" ]]; then
  pass "indented STATUS line is detected (claude REPL indents by 2 spaces)"
else
  fail "indented STATUS line is detected (claude REPL indents by 2 spaces)" "got: $status"
fi

# Assistant-marker prefix case: claude's REPL prefixes the FIRST line of an
# assistant response with `⏺ ` (assistant indicator). When the receiver
# emits `STATUS: WORK_IN_PROGRESS` as its first line per the ringing-skill
# protocol, the on-screen line is `⏺ STATUS: WORK_IN_PROGRESS`, not just
# `STATUS: WORK_IN_PROGRESS`. The extractor must accept that prefix or the
# buf-reset never fires and the response body accumulates the entire screen
# (preamble, banner, /hotline:ringing line, tool-call chrome, …) before the
# actual answer. Reproduced live on the 2026-05-14 PR #803 status dial.
screen=$'shell preamble line\n/hotline:ringing [MODE: quick_call] hello\ngh output noise\n⏺ STATUS: WORK_IN_PROGRESS\n\n  PR #803 — actual answer\n  - state: open\n  STATUS: DONE\n'
status=$(printf '%s' "$screen" | latest_status)
response=$(printf '%s' "$screen" | extract_cmux_response)

if [[ "$status" == "STATUS: DONE" ]]; then
  pass "⏺-prefixed STATUS is detected"
else
  fail "⏺-prefixed STATUS is detected" "got: $status"
fi
if [[ "$response" == *"PR #803 — actual answer"* && "$response" != *"shell preamble"* && "$response" != *"hotline:ringing"* ]]; then
  pass "⏺-prefixed WORK_IN_PROGRESS resets buf — preamble is excluded from response"
else
  fail "⏺-prefixed WORK_IN_PROGRESS resets buf — preamble is excluded from response" \
       "got: $(printf '%q' "$response")"
fi

# Trailing-chrome case: the LAST line in the screen is shell/REPL chrome,
# not the STATUS. Confirms "latest STATUS anywhere wins" so the real STATUS
# above the trailing chrome still terminates the call.
screen=$'response body\nSTATUS: DONE\n /tmp  \n'
status=$(printf '%s' "$screen" | latest_status)
if [[ "$status" == "STATUS: DONE" ]]; then
  pass "STATUS still detected when trailing chrome follows it"
else
  fail "STATUS still detected when trailing chrome follows it" "got: $status"
fi

# Quoted-STATUS case: a single quoted line containing STATUS inside the
# response body (e.g., a protocol explanation) followed by the real
# terminal STATUS. The real STATUS comes last, so it wins.
screen=$'Here is how the protocol works:\nSTATUS: WORK_COMPLETE means done.\nSTATUS: DONE\n'
status=$(printf '%s' "$screen" | latest_status)
if [[ "$status" == "STATUS: DONE" ]]; then
  pass "real STATUS wins when quoted STATUS appears earlier in body"
else
  fail "real STATUS wins when quoted STATUS appears earlier in body" \
       "got: $status"
fi

tmp=$(mktemp -d /tmp/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "new-workspace" ]]; then
  echo "boom from new-workspace" >&2
  exit 42
fi
exit 0
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" \
  > "$tmp/out.json" 2> "$tmp/stderr.txt"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "new-workspace failure exits after returning call_dir"
else
  fail "new-workspace failure exits after returning call_dir" "exit code: $rc"
fi
assert_async_error_contract "new-workspace failure" "$tmp"
rm -rf "$tmp"

tmp=$(mktemp -d /tmp/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  new-workspace) echo "OK workspace:123" ;;
  read-screen) echo "$ " ;;
  send)
    echo "boom from send" >&2
    exit 43
    ;;
  close-workspace) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" \
  > "$tmp/out.json" 2> "$tmp/stderr.txt"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "send failure exits after returning call_dir"
else
  fail "send failure exits after returning call_dir" "exit code: $rc"
fi
assert_async_error_contract "send failure" "$tmp"
rm -rf "$tmp"

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
