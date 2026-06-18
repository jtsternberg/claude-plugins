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

# Case 3b: no banner, but transcript file exists (Signal B) → session_id.txt
# promoted from preset. Verifies the second REPL-boot signal independently.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
Last login: Thu May 14 16:00:00 on ttys001
 some shell prompt with no banner yet
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-3b" "workspace:99"
# Stage the receiver's cwd + a non-empty transcript file under a fake HOME.
RECV_CWD="/Users/fake/Code/proj.name"
echo "$RECV_CWD" > "$cd/cwd.txt"
ENC=$(printf '%s' "$RECV_CWD" | sed 's|[/.]|-|g')
mkdir -p "$tmp/home/.claude/projects/$ENC"
echo '{"type":"user"}' > "$tmp/home/.claude/projects/$ENC/preset-uuid-3b.jsonl"

out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 5 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "preset-uuid-3b" ]]; then
  pass "transcript-file signal: prints preset session id without banner"
else
  fail "transcript-file signal: prints preset session id without banner" \
       "rc=$rc stdout=$out stderr=$(cat "$tmp/err.txt")"
fi
if [[ -f "$cd/session_id.txt" && "$(cat "$cd/session_id.txt")" == "preset-uuid-3b" ]]; then
  pass "transcript-file signal: promotes session_id_preset.txt → session_id.txt"
else
  fail "transcript-file signal: promotes session_id_preset.txt → session_id.txt"
fi
rm -rf "$tmp"

# Case 3c: no banner AND no transcript file → timeout, error message
# enumerates which signals were missing (actionable diagnostic).
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
echo "no banner here" > "$tmp/screen.txt"
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-3c" "workspace:99"
RECV_CWD="/Users/fake/Code/proj"
echo "$RECV_CWD" > "$cd/cwd.txt"
mkdir -p "$tmp/home/.claude/projects"  # but no transcript

out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 2 2>"$tmp/err.txt")
rc=$?
if [[ $rc -ne 0 ]] && grep -q "no transcript file" "$tmp/err.txt"; then
  pass "neither signal: timeout error names the missing transcript path"
else
  fail "neither signal: timeout error names the missing transcript path" \
       "rc=$rc stderr=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# Case 3d: empty transcript file (claude created it but hasn't written yet)
# is NOT enough — we require -s (non-empty). Banner remains the only signal.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
echo "no banner" > "$tmp/screen.txt"
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-3d" "workspace:99"
RECV_CWD="/Users/fake/Code/proj"
echo "$RECV_CWD" > "$cd/cwd.txt"
ENC=$(printf '%s' "$RECV_CWD" | sed 's|[/.]|-|g')
mkdir -p "$tmp/home/.claude/projects/$ENC"
: > "$tmp/home/.claude/projects/$ENC/preset-uuid-3d.jsonl"  # empty

out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 2 2>"$tmp/err.txt")
rc=$?
if [[ $rc -ne 0 && ! -f "$cd/session_id.txt" ]]; then
  pass "empty transcript file does NOT count as a liveness signal"
else
  fail "empty transcript file does NOT count as a liveness signal" \
       "rc=$rc session_id.txt exists=$([[ -f "$cd/session_id.txt" ]] && echo yes || echo no)"
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
echo "Surface mode (side-by-side / --window placement):"

# Stage a call_dir mimicking the surface-placement launcher output:
# surface_ref.txt (NOT workspace_ref.txt) is the surface-mode signal.
stage_surface_call_dir() {
  local cd="$1" preset="$2" surf_ref="$3" keep="${4:-true}"
  mkdir -p "$cd"
  echo "$preset"   > "$cd/session_id_preset.txt"
  echo "$surf_ref" > "$cd/surface_ref.txt"
  echo "pane:55"   > "$cd/pane_ref.txt"
  echo "$keep"     > "$cd/keep_workspace.txt"
  echo "/tmp/hotline-launch-FAKE-$$" > "$cd/launch_script.txt"
}

# A fake cmux that records close-surface / close-workspace separately so we can
# assert surface mode closes the SURFACE, not a workspace.
make_surface_fake_cmux() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen)    cat "${CMUX_FAKE_SCREEN:?}" ;;
  close-surface)  echo "$@" >> "${CMUX_FAKE_STATE:?}/close_surface_calls" ;;
  close-workspace)echo "$@" >> "${CMUX_FAKE_STATE:?}/close_workspace_calls" ;;
  *)              exit 0 ;;
esac
EOF
  chmod +x "$bin_dir/cmux"
}

# Case S1: wait-for-session promotes session_id via the surface read-screen path.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_surface_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.141
▝▜█████▛▘  Opus 4.7
EOF
cd="$tmp/call"
stage_surface_call_dir "$cd" "surf-preset-1" "surface:777"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" CMUX_FAKE_STATE="$tmp" \
  bash "$WAIT_SESSION" "$cd" --timeout 5 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$out" == "surf-preset-1" ]]; then
  pass "surface mode: wait-for-session reads the surface and prints the session id"
else
  fail "surface mode: wait-for-session reads the surface and prints the session id" \
       "rc=$rc stdout=$out stderr=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# Case S2: wait-for-response extracts STATUS via the surface and, with keep=true
# (the surface-mode default), does NOT close the surface or any workspace.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_surface_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.141
STATUS: WORK_IN_PROGRESS
side-by-side answer body
STATUS: WORK_COMPLETE
EOF
cd="$tmp/call"
stage_surface_call_dir "$cd" "surf-preset-2" "surface:777" "true"
echo "surf-preset-2" > "$cd/session_id.txt"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" CMUX_FAKE_STATE="$tmp" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 10 2>"$tmp/err.txt")
rc=$?
resp=$(echo "$out" | jq -r '.response' 2>/dev/null || echo "")
if [[ $rc -eq 0 && "$resp" == *"side-by-side answer body"* ]]; then
  pass "surface mode: wait-for-response extracts the body from the surface"
else
  fail "surface mode: wait-for-response extracts the body from the surface" \
       "rc=$rc resp=$(printf '%q' "$resp") stderr=$(cat "$tmp/err.txt")"
fi
if [[ ! -f "$tmp/close_surface_calls" && ! -f "$tmp/close_workspace_calls" ]]; then
  pass "surface mode: keep=true leaves the surface open (no close-surface/close-workspace)"
else
  fail "surface mode: keep=true leaves the surface open" \
       "surface=$(cat "$tmp/close_surface_calls" 2>/dev/null) workspace=$(cat "$tmp/close_workspace_calls" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case S3: with keep=false, surface mode closes the SURFACE (close-surface),
# never close-workspace (which would nuke the caller's own window).
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_surface_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.141
done body
STATUS: DONE
EOF
cd="$tmp/call"
stage_surface_call_dir "$cd" "surf-preset-3" "surface:777" "false"
echo "surf-preset-3" > "$cd/session_id.txt"
PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" CMUX_FAKE_STATE="$tmp" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 5 >/dev/null 2>"$tmp/err.txt"
if grep -q "close-surface --surface surface:777" "$tmp/close_surface_calls" 2>/dev/null; then
  pass "surface mode: keep=false closes the SURFACE"
else
  fail "surface mode: keep=false closes the SURFACE" \
       "calls=$(cat "$tmp/close_surface_calls" 2>/dev/null || echo NONE)"
fi
if [[ ! -f "$tmp/close_workspace_calls" ]]; then
  pass "surface mode: never calls close-workspace (would kill the caller's window)"
else
  fail "surface mode: never calls close-workspace" \
       "calls=$(cat "$tmp/close_workspace_calls")"
fi
rm -rf "$tmp"

# Case S4 (CALL_ID nonce on the new path): a replayed STATUS line WITHOUT the
# nonce (e.g. --resume scrollback) must be ignored; only the fresh STATUS that
# carries call_id=<nonce> terminates the call. Mirrors the workspace-mode
# guarantee but proves it holds when polling a surface.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_surface_fake_cmux "$tmp/bin"
# Realistic scrollback: a prior call's transcript was replayed (un-nonced
# STATUS lines), then THIS call's fresh turn runs — beginning, per the ringing
# protocol, with a nonce-tagged WORK_IN_PROGRESS that resets the body buffer.
cat > "$tmp/screen.txt" <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.141
replayed stale body from a prior call
STATUS: WORK_COMPLETE
STATUS: WORK_IN_PROGRESS call_id=abcdef0123456789
fresh body for THIS call
STATUS: WORK_COMPLETE call_id=abcdef0123456789
EOF
cd="$tmp/call"
stage_surface_call_dir "$cd" "surf-preset-4" "surface:777" "true"
echo "surf-preset-4" > "$cd/session_id.txt"
echo "abcdef0123456789" > "$cd/call_id.txt"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" CMUX_FAKE_STATE="$tmp" \
  bash "$WAIT_RESPONSE" "$cd" --timeout 10 2>"$tmp/err.txt")
resp=$(echo "$out" | jq -r '.response' 2>/dev/null || echo "")
if [[ "$resp" == *"fresh body for THIS call"* && "$resp" != *"replayed stale body"* ]]; then
  pass "surface mode: nonce-matched STATUS wins; un-nonced replayed STATUS ignored"
else
  fail "surface mode: nonce-matched STATUS wins; un-nonced replayed STATUS ignored" \
       "resp=$(printf '%q' "$resp")"
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
