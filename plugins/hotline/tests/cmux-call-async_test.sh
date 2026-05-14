#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-call-async.sh logic that can be exercised without
# launching cmux or Claude.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

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
    printf ' %q\n' "$prompt"
  }
}

latest_status() {
  awk '/^STATUS: /{status=$0} END{print status}'
}

extract_cmux_response() {
  grep -v "^bash /tmp/hotline-launch" \
    | grep -vE "^[╭│╰ℹ─]" \
    | grep -vE "^> $" \
    | awk '
        /^STATUS: WORK_IN_PROGRESS$/ {buf=""; next}
        /^STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE)$/ {printf "%s", buf; exit}
        {buf = buf $0 ORS}
      '
}

echo "cmux-call-async regression:"

script=$(build_launch_script "" "11111111-1111-4111-8111-111111111111" false "hotline test" "Bash(git *) Edit" "hello")
if printf '%s' "$script" | bash -n 2> /tmp/hotline-cmux-test.err; then
  pass "launch script quotes complex --tools specs"
else
  fail "launch script quotes complex --tools specs" "$(cat /tmp/hotline-cmux-test.err)"
fi
rm -f /tmp/hotline-cmux-test.err

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

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
