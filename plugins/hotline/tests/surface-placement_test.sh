#!/usr/bin/env bash
# =============================================================================
# Tests for the hotline-net-new surface-placement primitives:
#   surface-ready.sh        — PTY-readiness probe (used by the --window path)
#   open-window-surface.sh  — find-or-create window, land a surface
#
# The side-by-side split-vs-adjacent decision tree is NOT tested here: hotline
# no longer carries a copy of it — it resolves and calls cmux-cli's canonical
# open-side-surface.sh at runtime (covered by the resolution + degrade tests in
# cmux-call-async_test.sh / cmux-call_test.sh, and by cmux-cli's own suite).
#
# Each protected gotcha from the work order has a named case here against the
# surface path:
#   • "Terminal surface not found" → readiness focus-pane's the pane first.
#   • Fresh-PTY race (swallowed \n)  → readiness RE-SENDS the probe and only
#                                       reports ready on >=2 marker hits.
#   • --focus true PTY requirement  → window-mode surfaces are created --focus true.
#   • cmuxOnly Broken pipe          → cmux-call-async.sh runs NO detached poller
#                                       (static check; polling lives in wait-*).
# Driven entirely by a shimmed `cmux` on PATH — never touches real cmux.
# =============================================================================
set -u

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts"
READY="$SCRIPTS/surface-ready.sh"
WIN="$SCRIPTS/open-window-surface.sh"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

echo "surface-ready.sh:"

# Case R1 (Terminal-surface-not-found): focus-pane is invoked before probing,
# forcing the PTY backend to attach. Also a happy-path ready: the fake echoes
# the marker back (typed + executed) so read-screen reports >=2 hits.
tmp=$(mktemp -d /tmp/hotline-ready-XXXXXX); mkdir -p "$tmp/bin"
: > "$tmp/screen.txt"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  focus-pane) echo "$*" >> "$ST/focus_calls" ;;
  send)
    echo "$*" >> "$ST/send_calls"
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    [[ -n "$m" ]] && { echo "$m"; echo "$m"; } >> "$ST/screen.txt"
    ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$READY" --surface surface:777 --pane pane:55 --timeout 5 2>"$tmp/err.txt"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "readiness reports ready once the probe echoes back"
else
  fail "readiness reports ready once the probe echoes back" "rc=$rc err=$(cat "$tmp/err.txt")"
fi
if grep -q "focus-pane --pane pane:55" "$tmp/focus_calls" 2>/dev/null; then
  pass "readiness focus-pane's the pane first (avoids 'Terminal surface not found')"
else
  fail "readiness focus-pane's the pane first" "focus=$(cat "$tmp/focus_calls" 2>/dev/null || echo NONE)"
fi
rm -rf "$tmp"

# Case R2 (fresh-PTY race): the first probe's \n is swallowed (no marker echoed);
# readiness must RE-SEND and succeed on the later attempt. The fake only echoes
# the marker on the 2nd+ send.
tmp=$(mktemp -d /tmp/hotline-ready-XXXXXX); mkdir -p "$tmp/bin"
: > "$tmp/screen.txt"; echo 0 > "$tmp/sendcount"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  focus-pane) : ;;
  send)
    n=$(( $(cat "$ST/sendcount") + 1 )); echo "$n" > "$ST/sendcount"
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    # Simulate the first \n being eaten by startup output: only echo on resend.
    if [[ -n "$m" && "$n" -ge 2 ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
    ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$READY" --surface surface:777 --pane pane:55 --timeout 6 2>"$tmp/err.txt"
rc=$?
sends=$(cat "$tmp/sendcount")
if [[ $rc -eq 0 && "$sends" -ge 2 ]]; then
  pass "readiness re-sends the probe and recovers a swallowed \\n (sent $sends times)"
else
  fail "readiness re-sends the probe and recovers a swallowed \\n" "rc=$rc sends=$sends"
fi
rm -rf "$tmp"

# Case R3: PTY never echoes → timeout exit 3 (surface exists but not ready).
tmp=$(mktemp -d /tmp/hotline-ready-XXXXXX); mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen) echo "no marker ever" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$READY" --surface surface:777 --pane pane:55 --timeout 1 2>"$tmp/err.txt"
rc=$?
if [[ $rc -eq 3 ]] && grep -q "timed out" "$tmp/err.txt"; then
  pass "readiness exits 3 with a diagnostic when the PTY never echoes"
else
  fail "readiness exits 3 with a diagnostic when the PTY never echoes" "rc=$rc err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

echo ""
echo "open-window-surface.sh find-or-create:"

# Case W1: window ref form → land a surface in that window's first workspace,
# created --focus true (the surface-mode --focus PTY requirement).
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  tree) echo '{"windows":[{"ref":"window:3","workspaces":[{"ref":"workspace:30","name":null,"panes":[{"ref":"pane:1","index":0}]}]}]}' ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:200 pane:9 workspace:30" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window window:3 --json 2>"$tmp/err.txt")
win=$(printf '%s' "$out" | jq -r '.window_ref // empty'); created=$(printf '%s' "$out" | jq -r '.created'); surf=$(printf '%s' "$out" | jq -r '.surface_ref // empty')
if [[ "$win" == "window:3" && "$created" == "false" && "$surf" == "surface:200" ]]; then
  pass "window ref form lands a surface in the existing window (created=false)"
else
  fail "window ref form lands a surface in the existing window" "win=$win created=$created surf=$surf err=$(cat "$tmp/err.txt")"
fi
if grep -q -- "--focus true" "$tmp/create_calls" 2>/dev/null; then
  pass "window-mode surface is created --focus true (PTY-attach requirement)"
else
  fail "window-mode surface is created --focus true" "calls=$(cat "$tmp/create_calls" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case W2: name form, a workspace titled <name> already exists → reuse its window.
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  tree) echo '{"windows":[{"ref":"window:2","workspaces":[{"ref":"workspace:5","name":"proj","panes":[{"ref":"pane:1","index":0}]}]}]}' ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:201 pane:9 workspace:5" ;;
  new-window)  echo "$*" >> "$ST/new_window_calls" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window proj --json 2>"$tmp/err.txt")
win=$(printf '%s' "$out" | jq -r '.window_ref // empty'); created=$(printf '%s' "$out" | jq -r '.created')
if [[ "$win" == "window:2" && "$created" == "false" && ! -f "$tmp/new_window_calls" ]]; then
  pass "name form reuses the window holding a workspace titled <name> (no new-window)"
else
  fail "name form reuses the existing named window" "win=$win created=$created newwin=$([[ -f "$tmp/new_window_calls" ]] && echo yes || echo no) err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# Case W3: name form, no match → new-window + new-workspace --name <name>, then surface.
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
echo 0 > "$tmp/made_window"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  tree) echo '{"windows":[{"ref":"window:1","workspaces":[{"ref":"workspace:5","name":"other","panes":[{"ref":"pane:1","index":0}]}]}]}' ;;
  list-windows)
    if [[ "$(cat "$ST/made_window")" == "1" ]]; then echo "window:1"; echo "window:9"; else echo "window:1"; fi ;;
  new-window) echo 1 > "$ST/made_window"; echo "OK window:9" ;;
  current-window) echo "window:9" ;;
  new-workspace) echo "$*" >> "$ST/new_ws_calls"; echo "OK workspace:90" ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:202 pane:9 workspace:90" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window newproj --working-directory /tmp/x --json 2>"$tmp/err.txt")
win=$(printf '%s' "$out" | jq -r '.window_ref // empty'); created=$(printf '%s' "$out" | jq -r '.created')
if [[ "$win" == "window:9" && "$created" == "true" ]]; then
  pass "name form with no match creates a new window (created=true)"
else
  fail "name form with no match creates a new window" "win=$win created=$created err=$(cat "$tmp/err.txt")"
fi
if grep -q -- "new-workspace --name newproj" "$tmp/new_ws_calls" 2>/dev/null; then
  pass "new window gets a workspace titled <name> so future --window <name> finds it"
else
  fail "new window gets a titled workspace" "calls=$(cat "$tmp/new_ws_calls" 2>/dev/null || echo NONE)"
fi
rm -rf "$tmp"

echo ""
echo "cmuxOnly Broken-pipe guard (architecture):"

# The launcher must NOT spawn a detached background poller — under cmux
# access_mode=cmuxOnly an orphaned subshell reparents to PID 1 and every cmux
# call returns "Broken pipe". Polling lives in wait-for-*.sh (children of the
# caller's cmux-spawned bash). Static check: no nohup/disown and no line ending
# in a bare `&` (backgrounding) in the surface launcher.
ASYNC="$SCRIPTS/cmux-call-async.sh"
if ! grep -qE '(^|[^&])&[[:space:]]*$' "$ASYNC" && ! grep -qE '\b(nohup|disown)\b' "$ASYNC"; then
  pass "cmux-call-async.sh runs no detached poller (no nohup/disown/trailing &)"
else
  fail "cmux-call-async.sh runs no detached poller" \
       "found: $(grep -nE '(^|[^&])&[[:space:]]*$|\b(nohup|disown)\b' "$ASYNC")"
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
