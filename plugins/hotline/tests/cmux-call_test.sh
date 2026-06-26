#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-call.sh command construction without launching cmux.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
LAUNCH_SCRIPTS=()
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

# Default invocation: explicitly unset HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS so
# the test doesn't pick up a value from the developer's own shell/settings.json.
# --detached exercises the original new-workspace placement, whose launch-script
# construction is identical across placements. The side-by-side default is
# covered separately below (and in surface-placement_test.sh).
env -u HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS \
  PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$SCRIPT_UNDER_TEST" \
  --detached \
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
assert_contains "first-contact sends launch script" "$send_args" "send --workspace workspace:123 bash /tmp/hotline-cmux-launch-"
assert_contains "first-contact appends enter" "$send_args" "\\n"

launch_script=$(printf '%s' "$send_args" | sed -E 's/.*bash (\/tmp\/hotline-cmux-launch-[^\\[:space:]]+).*/\1/')
LAUNCH_SCRIPTS+=("$launch_script")
launch_body=$(cat "$launch_script" 2>/dev/null || true)
assert_contains "first-contact launch script runs claude" "$launch_body" "claude"
assert_contains "first-contact pre-sets session id" "$launch_body" "--session-id"
assert_contains "first-contact launch script contains conference prompt" "$launch_body" "/hotline-ringing"
assert_contains "first-contact preserves conference mode" "$launch_body" "conference_call"

# Regression: --allowedTools is variadic — must be terminated with `--` before
# the positional prompt or claude swallows the prompt as a tool name.
if printf '%s' "$launch_body" | grep -qE -- "--allowedTools .+ -- "; then
  pass "first-contact launch script puts -- before the positional prompt"
else
  fail "first-contact launch script puts -- before the positional prompt" \
       "got: $launch_body"
fi

# HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS is opt-in. Default (unset) must NOT
# add the flag; the above invocation didn't set it, so verify absence.
if printf '%s' "$launch_body" | grep -q -- "--dangerously-skip-permissions"; then
  fail "default launch does NOT include --dangerously-skip-permissions" \
       "got: $launch_body"
else
  pass "default launch does NOT include --dangerously-skip-permissions"
fi

session_id=$(jq -r '.session_id' "$tmp/out.json" 2>/dev/null || true)
if [[ "$session_id" =~ ^[0-9a-f-]{36}$ ]]; then
  pass "first-contact returns generated session id"
else
  fail "first-contact returns generated session id" "got: $session_id"
fi

PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$SCRIPT_UNDER_TEST" \
  --detached \
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
assert_contains "resume call sends launch script" "$send_args" "send --workspace workspace:123 bash /tmp/hotline-cmux-launch-"

launch_script=$(printf '%s' "$send_args" | sed -E 's/.*bash (\/tmp\/hotline-cmux-launch-[^\\[:space:]]+).*/\1/')
LAUNCH_SCRIPTS+=("$launch_script")
launch_body=$(cat "$launch_script" 2>/dev/null || true)
assert_contains "resume call keeps --resume" "$launch_body" "--resume"
assert_contains "resume call sends follow-up prompt" "$launch_body" "follow\\ up\\ message"

session_id=$(jq -r '.session_id' "$tmp/out2.json" 2>/dev/null || true)
if [[ "$session_id" == "resume id with spaces" ]]; then
  pass "resume call returns resume id"
else
  fail "resume call returns resume id" "got: $session_id"
fi

# HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 opt-in: third invocation with the
# env var set must include --dangerously-skip-permissions.
HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$SCRIPT_UNDER_TEST" \
  --detached \
  --cwd "$tmp/cwd" \
  --prompt "test perms" \
  > "$tmp/out3.json" 2> "$tmp/stderr3.txt"

send_args=$(cat "$tmp/send_args" 2>/dev/null || true)
launch_script=$(printf '%s' "$send_args" | sed -E 's/.*bash (\/tmp\/hotline-cmux-launch-[^\\[:space:]]+).*/\1/')
LAUNCH_SCRIPTS+=("$launch_script")
launch_body=$(cat "$launch_script" 2>/dev/null || true)

if printf '%s' "$launch_body" | grep -q -- "--dangerously-skip-permissions"; then
  pass "HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 adds --dangerously-skip-permissions"
else
  fail "HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 adds --dangerously-skip-permissions" \
       "got: $launch_body"
fi

rm -f "${LAUNCH_SCRIPTS[@]}"
rm -rf "$tmp"

# --- Default placement: side-by-side surface ---------------------------------
# With no --detached, cmux-call.sh RESOLVES and calls cmux-cli's canonical
# open-side-surface.sh (injected here via a stub), then sends the launch script
# to that SURFACE, not a new workspace.
tmp=$(mktemp -d /tmp/hotline-cmux-call-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "invoked: $*" >> "${SIDE_STUB_LOG:?}"
printf '%s\n' '{"surface_ref":"surface:777","pane_ref":"pane:55","workspace_ref":"workspace:5","ready":"ready"}'
EOF
chmod +x "$tmp/open-side.sh"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  send) echo "$*" >> "$ST/send_calls" ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"

env -u HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS \
  PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" \
  --cwd "$tmp/cwd" --name "sbs test" \
  --prompt "/hotline-ringing [MODE: conference_call] [CALLER: /caller] [SESSION: abc] hi" \
  > "$tmp/out.json" 2> "$tmp/stderr.txt"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "side-by-side default exits successfully"
else
  fail "side-by-side default exits successfully" "rc=$rc stderr=$(cat "$tmp/stderr.txt")"
fi

if grep -q "invoked:.*--wait-ready" "$tmp/side_log" 2>/dev/null; then
  pass "side-by-side resolves and calls cmux-cli's opener with --wait-ready"
else
  fail "side-by-side resolves and calls cmux-cli's opener with --wait-ready" \
       "side_log=$(cat "$tmp/side_log" 2>/dev/null || echo NONE)"
fi

send_calls=$(cat "$tmp/send_calls" 2>/dev/null || true)
assert_contains "side-by-side sends launch script to the SURFACE (not a workspace)" \
  "$send_calls" "send --surface surface:777 bash /tmp/hotline-cmux-launch-"

placement=$(jq -r '.placement // empty' "$tmp/out.json" 2>/dev/null || true)
surf_ref=$(jq -r '.surface_ref // empty' "$tmp/out.json" 2>/dev/null || true)
ws_ref=$(jq -r '.workspace_ref // "null"' "$tmp/out.json" 2>/dev/null || true)
if [[ "$placement" == "surface" && "$surf_ref" == "surface:777" && "$ws_ref" == "null" ]]; then
  pass "side-by-side reports placement=surface with surface_ref and null workspace_ref"
else
  fail "side-by-side reports placement=surface with surface_ref and null workspace_ref" \
       "placement=$placement surface_ref=$surf_ref workspace_ref=$ws_ref"
fi
ls=$(printf '%s' "$send_calls" | sed -E 's/.*bash (\/tmp\/hotline-cmux-launch-[^\\[:space:]]+).*/\1/' | tail -1)
rm -f "$ls" 2>/dev/null || true
rm -rf "$tmp"

# --- Headless fallback: cmux present, cmux-cli opener absent -----------------
tmp=$(mktemp -d /tmp/hotline-cmux-call-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd" "$tmp/empty"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${CMUX_FAKE_STATE:?}/cmux_calls"
exit 0
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/nope.sh" HOTLINE_PLUGINS_DIR="$tmp/empty" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hi" 2>"$tmp/stderr.txt")
fb=$(printf '%s' "$out" | jq -r '.fallback // empty' 2>/dev/null)
if [[ "$fb" == "headless" && ! -f "$tmp/cmux_calls" ]]; then
  pass "missing opener signals fallback:headless and touches no cmux"
else
  fail "missing opener signals fallback:headless and touches no cmux" \
       "out=$out cmux_calls=$(cat "$tmp/cmux_calls" 2>/dev/null || echo NONE)"
fi
rm -rf "$tmp"

# --fork-session without --resume must hard-error (forking with no resume target
# silently creates an empty session — the bug this guard prevents).
fork_out=$(bash "$SCRIPT_UNDER_TEST" --cwd /tmp --prompt "hello" --fork-session 2>&1)
fork_rc=$?
if [[ $fork_rc -eq 1 ]] && printf '%s' "$fork_out" | grep -q "fork-session requires --resume"; then
  pass "--fork-session without --resume errors and exits 1"
else
  fail "--fork-session without --resume errors and exits 1" "rc=$fork_rc out=$fork_out"
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
