#!/usr/bin/env bash
# =============================================================================
# Regression tests for the cmux-mode branches of wait-for-session.sh and
# wait-for-response.sh.
#
# Each test stages a call_dir that looks like the one cmux-call-async.sh
# leaves behind (workspace_ref.txt, session_id_preset.txt, launch_script.txt,
# keep_workspace.txt), shims `cmux` on PATH to return canned read-screen
# output, and asserts the wait scripts do the right thing without ever
# touching real cmux.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

WAIT_SESSION="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/wait-for-session.sh"
WAIT_RESPONSE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/wait-for-response.sh"

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

# Create a fake cmux that emits a fixture file's contents for read-screen and
# no-ops everything else. Caller sets $tmp/screen.txt with the desired
# read-screen output.
make_fake_cmux() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen)
    cat "${CMUX_FAKE_SCREEN:?CMUX_FAKE_SCREEN not set}"
    ;;
  close-workspace)
    echo "OK ${4:-}"
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$bin_dir/cmux"
}

# Stage a call_dir mimicking cmux-call-async.sh's output.
stage_call_dir() {
  local cd="$1" preset="$2" ws_ref="$3" keep="${4:-false}"
  mkdir -p "$cd"
  echo "$preset" > "$cd/session_id_preset.txt"
  echo "$ws_ref" > "$cd/workspace_ref.txt"
  echo "$keep"   > "$cd/keep_workspace.txt"
  echo "/tmp/hotline-launch-FAKE-$$" > "$cd/launch_script.txt"
}

echo "wait-for-session cmux mode:"

# Case 1: REPL banner visible → session_id.txt promoted from preset.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
Last login: Thu May 14 16:00:00 on ttys001
 ▐▛███▜▌   Claude Code v2.1.141
▝▜█████▛▘  Opus 4.7
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-1" "workspace:99"

out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 5 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "preset-uuid-1" ]]; then
  pass "splash visible: prints preset session id"
else
  fail "splash visible: prints preset session id" "rc=$rc stdout=$out stderr=$(cat "$tmp/err.txt")"
fi
if [[ -f "$cd/session_id.txt" && "$(cat "$cd/session_id.txt")" == "preset-uuid-1" ]]; then
  pass "splash visible: promotes session_id_preset.txt → session_id.txt"
else
  fail "splash visible: promotes session_id_preset.txt → session_id.txt"
fi
rm -rf "$tmp"

# Case 2: no banner → times out with actionable error.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
Last login: Thu May 14 16:00:00 on ttys001
 lindrisbackend  master  bash /tmp/hotline-launch-something
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-2" "workspace:99"

out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 2 2>"$tmp/err.txt")
rc=$?
if [[ $rc -ne 0 ]]; then
  pass "no banner: exits non-zero on timeout"
else
  fail "no banner: exits non-zero on timeout" "rc=$rc"
fi
if grep -q "Claude REPL to boot" "$tmp/err.txt"; then
  pass "no banner: stderr explains the failure"
else
  fail "no banner: stderr explains the failure" "stderr=$(cat "$tmp/err.txt")"
fi
if [[ ! -f "$cd/session_id.txt" ]]; then
  pass "no banner: session_id.txt is NOT promoted"
else
  fail "no banner: session_id.txt is NOT promoted"
fi
rm -rf "$tmp"

# Case 3: launcher already wrote done+error.txt → wait-for-session exits 1
# with the launcher's error on stderr (early-fail propagation).
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
echo "" > "$tmp/screen.txt"
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-3" "workspace:99"
echo '{"error":"launcher boom"}' > "$cd/error.txt"
touch "$cd/done"

out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 5 2>"$tmp/err.txt")
rc=$?
if [[ $rc -ne 0 ]] && grep -q "launcher boom" "$tmp/err.txt"; then
  pass "early launcher failure short-circuits with the launcher's error"
else
  fail "early launcher failure short-circuits with the launcher's error" \
       "rc=$rc stderr=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

echo ""
echo "wait-for-response cmux mode:"

# Case 4: STATUS: DONE on screen → response.json + done written, JSON emitted.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
bash /tmp/hotline-launch-XYZ
 ▐▛███▜▌   Claude Code v2.1.141
STATUS: WORK_IN_PROGRESS
the answer is 42
STATUS: DONE
 /tmp
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-4" "workspace:99"
echo "preset-uuid-4" > "$cd/session_id.txt"

out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 10 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "STATUS: DONE → exit 0"
else
  fail "STATUS: DONE → exit 0" "rc=$rc stderr=$(cat "$tmp/err.txt")"
fi
sid=$(echo "$out" | jq -r '.session_id' 2>/dev/null || echo "")
resp=$(echo "$out" | jq -r '.response' 2>/dev/null || echo "")
if [[ "$sid" == "preset-uuid-4" ]]; then
  pass "STATUS: DONE → emits the session id"
else
  fail "STATUS: DONE → emits the session id" "got: $sid"
fi
if [[ "$resp" == *"the answer is 42"* ]]; then
  pass "STATUS: DONE → response body extracted"
else
  fail "STATUS: DONE → response body extracted" "got: $(printf '%q' "$resp")"
fi
if [[ -f "$cd/response.json" && -f "$cd/done" ]]; then
  pass "STATUS: DONE → response.json + done written"
else
  fail "STATUS: DONE → response.json + done written"
fi
rm -rf "$tmp"

# Case 5: WORK_IN_PROGRESS only, no terminal status → timeout, error written.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
bash /tmp/hotline-launch-XYZ
STATUS: WORK_IN_PROGRESS
still working...
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-5" "workspace:99"
echo "preset-uuid-5" > "$cd/session_id.txt"

out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 3 2>"$tmp/err.txt")
rc=$?
if [[ $rc -ne 0 ]] && grep -q "Timed out waiting for STATUS" "$tmp/err.txt"; then
  pass "WORK_IN_PROGRESS forever → timeout with clear error"
else
  fail "WORK_IN_PROGRESS forever → timeout with clear error" \
       "rc=$rc stderr=$(cat "$tmp/err.txt")"
fi
if [[ -f "$cd/done" && -f "$cd/error.txt" ]]; then
  pass "timeout writes done + error.txt for future callers"
else
  fail "timeout writes done + error.txt for future callers"
fi
rm -rf "$tmp"

# Case 6: keep_workspace=true → cmux close-workspace is NOT called.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen)   cat "${CMUX_FAKE_SCREEN:?}" ;;
  close-workspace)
    echo "$@" >> "${CMUX_FAKE_STATE:?}/close_calls"
    ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
cat > "$tmp/screen.txt" <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.141
done body
STATUS: DONE
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-6" "workspace:99" "true"
echo "preset-uuid-6" > "$cd/session_id.txt"

PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" CMUX_FAKE_STATE="$tmp" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 5 > /dev/null 2>"$tmp/err.txt"
if [[ ! -f "$tmp/close_calls" ]]; then
  pass "keep_workspace=true skips cmux close-workspace"
else
  fail "keep_workspace=true skips cmux close-workspace" \
       "close calls: $(cat "$tmp/close_calls")"
fi
rm -rf "$tmp"

# Case 7: keep_workspace=false (default) → cmux close-workspace IS called.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen)   cat "${CMUX_FAKE_SCREEN:?}" ;;
  close-workspace)
    echo "$@" >> "${CMUX_FAKE_STATE:?}/close_calls"
    ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
cat > "$tmp/screen.txt" <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.141
done body
STATUS: DONE
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-7" "workspace:99" "false"
echo "preset-uuid-7" > "$cd/session_id.txt"

PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" CMUX_FAKE_STATE="$tmp" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 5 > /dev/null 2>"$tmp/err.txt"
if grep -q "close-workspace.*workspace:99" "$tmp/close_calls" 2>/dev/null; then
  pass "keep_workspace=false closes the workspace after STATUS"
else
  fail "keep_workspace=false closes the workspace after STATUS" \
       "close calls: $(cat "$tmp/close_calls" 2>/dev/null || echo NONE)"
fi
rm -rf "$tmp"

# Case 8: headless mode (no workspace_ref.txt) — original file-watch path
# still works. wait-for-response.sh should poll done + emit response.json.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
cd="$tmp/call"
mkdir -p "$cd"
echo "preset-uuid-8" > "$cd/session_id.txt"
echo '{"session_id":"preset-uuid-8","response":"headless body"}' > "$cd/response.json"
touch "$cd/done"

out=$(bash "$WAIT_RESPONSE" "$cd" --timeout 5 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 ]] && [[ "$(echo "$out" | jq -r '.response')" == "headless body" ]]; then
  pass "headless mode (no workspace_ref.txt) still emits response.json"
else
  fail "headless mode (no workspace_ref.txt) still emits response.json" \
       "rc=$rc stdout=$out stderr=$(cat "$tmp/err.txt")"
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
