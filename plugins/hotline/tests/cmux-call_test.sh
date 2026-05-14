#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-call.sh command construction without launching cmux.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/cmux-call.sh"

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

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "missing: $needle; got: $haystack"
  fi
}

echo "cmux-call regression:"

tmp=$(mktemp -d /tmp/hotline-cmux-call-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  new-workspace)
    echo "OK workspace:123"
    ;;
  send)
    printf '%s' "$*" > "${CMUX_FAKE_STATE:?}/send_args"
    ;;
esac
EOF
chmod +x "$tmp/bin/cmux"

PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$SCRIPT_UNDER_TEST" \
  --cwd "$tmp/cwd" \
  --name "hotline test" \
  --tools "Bash(git *) Edit" \
  --prompt "/hotline-ringing [MODE: conference_call] [CALLER: /caller] [SESSION: abc] hello there" \
  > "$tmp/out.json" 2> "$tmp/stderr.txt"
rc=$?

if [[ $rc -eq 0 ]]; then
  pass "first-contact conference call exits successfully"
else
  fail "first-contact conference call exits successfully" "exit code: $rc stderr=$(cat "$tmp/stderr.txt")"
fi

send_args=$(cat "$tmp/send_args" 2>/dev/null || true)
assert_contains "first-contact sends claude command" "$send_args" "send --workspace workspace:123 claude"
assert_contains "first-contact pre-sets session id" "$send_args" "--session-id"
assert_contains "first-contact sends conference prompt" "$send_args" "/hotline-ringing"
assert_contains "first-contact preserves conference mode" "$send_args" "conference_call"
assert_contains "first-contact appends enter" "$send_args" "\\n"

session_id=$(jq -r '.session_id' "$tmp/out.json" 2>/dev/null || true)
if [[ "$session_id" =~ ^[0-9a-f-]{36}$ ]]; then
  pass "first-contact returns generated session id"
else
  fail "first-contact returns generated session id" "got: $session_id"
fi

PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$SCRIPT_UNDER_TEST" \
  --cwd "$tmp/cwd" \
  --resume "resume id with spaces" \
  --prompt "follow up message" \
  > "$tmp/out2.json" 2> "$tmp/stderr2.txt"
rc=$?

if [[ $rc -eq 0 ]]; then
  pass "resume call exits successfully"
else
  fail "resume call exits successfully" "exit code: $rc stderr=$(cat "$tmp/stderr2.txt")"
fi

send_args=$(cat "$tmp/send_args" 2>/dev/null || true)
assert_contains "resume call keeps --resume" "$send_args" "--resume"
assert_contains "resume call sends follow-up prompt" "$send_args" "follow\\ up\\ message"

session_id=$(jq -r '.session_id' "$tmp/out2.json" 2>/dev/null || true)
if [[ "$session_id" == "resume id with spaces" ]]; then
  pass "resume call returns resume id"
else
  fail "resume call returns resume id" "got: $session_id"
fi

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
