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
#   • "Terminal surface not found" → the readiness PROBE SEND is what attaches the
#                                       PTY; nothing focuses (claude-plugins-r465.4).
#   • Fresh-PTY race (swallowed \n)  → readiness RE-SENDS the probe and only
#                                       reports ready on >=2 marker hits.
#   • Focus theft                    → creation verbs pass --focus false, readiness
#                                       calls no focus-pane, and every send/read is
#                                       refused on an empty handle (cmux would
#                                       resolve it to the FOCUSED surface).
#   • User-scrolled panes            → every read carries --scrollback, so a frozen
#                                       viewport cannot read as "not ready yet".
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

# Case R1 (happy path): the SEND attaches the PTY, and the fake echoes the marker
# back (typed + executed) so the read reports >=2 hits.
#
# NOTHING FOCUSES. focus-pane also attaches the PTY, eagerly, but it does so by
# moving the user's cursor into the brand-new surface — so keystrokes they are
# typing at that instant land in the callee's shell, which is how a launch command
# became `rkebash /tmp/…` (2026-08-26). `cmux send` attaches the PTY on its own,
# verified live on cmux 0.64.22, so a focus call here is pure cost
# (claude-plugins-r465.4).
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
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
    ;;
  read-screen) echo "$*" >> "$ST/read_calls"; cat "$ST/screen.txt" 2>/dev/null ;;
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
if [[ ! -s "$tmp/focus_calls" ]]; then
  pass "readiness never steals focus (the send is what attaches the PTY)"
else
  fail "readiness never steals focus" "focus=$(cat "$tmp/focus_calls" 2>/dev/null)"
fi
# Ctrl-U (the raw 0x15 byte) precedes every probe, on the SAME handle. The input
# line is shared with the user, and `rkeecho __HOTLINE_PTYREADY_…__` puts the
# marker on screen twice — satisfying the >=2-hit test while proving nothing about
# the shell executing input (claude-plugins-r465.7).
# -a: the log holds a raw 0x15 byte, and GNU grep would otherwise treat the file
# as binary and refuse to print matches on the Linux runner.
clears=$(grep -ac $'\025$' "$tmp/send_calls" 2>/dev/null || true)
misaddressed=$(grep -a $'\025$' "$tmp/send_calls" 2>/dev/null | grep -vc '^send --surface surface:777' || true)
if [[ "$clears" -ge 1 && "$misaddressed" -eq 0 ]]; then
  pass "each probe is preceded by a Ctrl-U on the same handle"
else
  fail "each probe is preceded by a Ctrl-U on the same handle" \
       "clears=$clears misaddressed=$misaddressed sends=$(cat "$tmp/send_calls" 2>/dev/null)"
fi
# Scroll immunity: a plain read-screen returns the user's scrolled viewport, so a
# probe against a scrolled pane would spin to its ceiling against a surface that
# was ready seconds ago (claude-plugins-r465.5).
plain_reads=$(grep -vc -- '--scrollback' "$tmp/read_calls" 2>/dev/null || true)
if [[ -s "$tmp/read_calls" && "$plain_reads" -eq 0 ]]; then
  pass "every readiness read carries --scrollback (scroll-immune)"
else
  fail "every readiness read carries --scrollback (scroll-immune)" \
       "reads=$(cat "$tmp/read_calls" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case R1b: a WORKSPACE target. The detached placements (cmux-call.sh, and
# cmux-call-async.sh's do_detached) create a workspace rather than a surface, and
# a readiness wait there cannot be built on polling read-screen until it returns
# something: under --focus false that NEVER succeeds, because there is no tty until
# the first send. This same probe, addressed by --workspace, is what those paths
# call (claude-plugins-r465.4).
tmp=$(mktemp -d /tmp/hotline-ready-XXXXXX); mkdir -p "$tmp/bin"
: > "$tmp/screen.txt"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  send)
    echo "$*" >> "$ST/send_calls"
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
    ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$READY" --workspace workspace:42 --timeout 5 2>"$tmp/err.txt"
rc=$?
if [[ $rc -eq 0 ]] && grep -q -- '--workspace workspace:42' "$tmp/send_calls" 2>/dev/null; then
  pass "readiness accepts a --workspace target and probes it by workspace"
else
  fail "readiness accepts a --workspace target and probes it by workspace" \
       "rc=$rc sends=$(cat "$tmp/send_calls" 2>/dev/null) err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# Case R1c: an empty target — or none at all — is a usage error, never a default.
# `cmux send --surface ""` does not fail; it delivers to the FOCUSED surface, which
# on 2026-08-26 put probe keystrokes into an unrelated live claude session twice
# (claude-plugins-r465.7).
tmp=$(mktemp -d /tmp/hotline-ready-XXXXXX); mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${CMUX_FAKE_STATE:?}/calls"
exit 0
EOF
chmod +x "$tmp/bin/cmux"
: > "$tmp/calls"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$READY" --surface "" --timeout 2 >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 && ! -s "$tmp/calls" ]]; then
  pass "an empty --surface handle is a usage error and sends nothing"
else
  fail "an empty --surface handle is a usage error and sends nothing" \
       "rc=$rc calls=$(cat "$tmp/calls" 2>/dev/null)"
fi
: > "$tmp/calls"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$READY" --timeout 2 >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 && ! -s "$tmp/calls" ]]; then
  pass "no target flag at all is a usage error and sends nothing"
else
  fail "no target flag at all is a usage error and sends nothing" \
       "rc=$rc calls=$(cat "$tmp/calls" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case R2 (fresh-PTY race): the first probe's \n is swallowed (no marker echoed);
# readiness must RE-SEND and succeed on the later attempt. The fake only echoes
# the marker on the 2nd+ send.
tmp=$(mktemp -d /tmp/hotline-ready-XXXXXX); mkdir -p "$tmp/bin"
: > "$tmp/screen.txt"; echo 0 > "$tmp/sendcount"
# Counts PROBE sends only. Each probe is now preceded by a Ctrl-U on the same
# handle, so counting every send would make the first probe look like the second.
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  focus-pane) : ;;
  send)
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    [[ -z "$m" ]] && exit 0
    n=$(( $(cat "$ST/sendcount") + 1 )); echo "$n" > "$ST/sendcount"
    # Simulate the first \n being eaten by startup output: only echo on resend.
    if [[ "$n" -ge 2 ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
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
# created --focus false (nothing needs focus; the first send attaches the PTY).
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
# --focus false, and NOT because focus is merely unnecessary: focus moves the
# user's cursor into the callee's brand-new pane, so anything they are typing at
# that instant goes to the callee's shell — the `rkebash /tmp/…` incident
# (2026-08-26). `cmux send` attaches the PTY on its own, verified live on cmux
# 0.64.22 for exactly this pairing (new-workspace --focus false + new-surface
# --focus false in a fresh window: probe sent, executed, ~0.8s, user's focus
# untouched). (claude-plugins-r465.4)
if grep -q -- "--focus false" "$tmp/create_calls" 2>/dev/null \
   && ! grep -q -- "--focus true" "$tmp/create_calls" 2>/dev/null; then
  pass "window-mode surface is created --focus false (never steals the user's focus)"
else
  fail "window-mode surface is created --focus false" "calls=$(cat "$tmp/create_calls" 2>/dev/null)"
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
