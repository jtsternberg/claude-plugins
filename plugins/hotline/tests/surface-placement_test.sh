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
  # A workspace's title lives under `title` in the real tree — there is no `name`
  # key on a workspace object, and matching the wrong one made every
  # `--window <name>` call miss and open a second window (claude-plugins-3ako).
  tree) echo '{"windows":[{"id":"WIN-B","ref":"window:2","workspaces":[{"id":"WS-P","ref":"workspace:5","title":"proj","panes":[{"ref":"pane:1","index":0}]}]}]}' ;;
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
#
# THE STUB SPEAKS REAL CMUX. `cmux list-windows` prints `* 0: <UUID>
# selected_workspace=<UUID> workspaces=N` and `cmux current-window` prints a bare
# UUID — neither emits a `window:N` token. The earlier version of this stub had
# both of them printing `window:9`, an output no cmux has ever produced, so the
# suite passed while `--window <name>` was dead in the field for every name that
# did not already exist (claude-plugins-3ako). A stub that can only be satisfied
# by the real output shapes is the only thing that catches that class.
#
# AND THE REF IS NOT THE INDEX. The new window is index 1 in list-windows and
# `window:4` in the tree, so a fix that maps the printed index to `window:<index>`
# targets window:1 — the user's existing window — and this case fails.
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
echo 0 > "$tmp/made_window"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
WIN_A="AD03B5BA-2CBD-4F0F-ABFF-3F6629BCFEBA"
WIN_B="440EF69F-1A97-41F2-A2FD-005D49AD7B87"
made=$(cat "$ST/made_window" 2>/dev/null || echo 0)
case "$1" in
  tree)
    if [[ "$made" == "1" ]]; then
      printf '{"windows":[{"id":"%s","ref":"window:1","index":0,"current":false,"workspaces":[{"id":"WS-A","ref":"workspace:5","title":"other","panes":[{"ref":"pane:1","index":0}]}]},{"id":"%s","ref":"window:4","index":1,"current":true,"workspaces":[]}]}\n' "$WIN_A" "$WIN_B"
    else
      printf '{"windows":[{"id":"%s","ref":"window:1","index":0,"current":true,"workspaces":[{"id":"WS-A","ref":"workspace:5","title":"other","panes":[{"ref":"pane:1","index":0}]}]}]}\n' "$WIN_A"
    fi ;;
  list-windows)
    printf '* 0: %s selected_workspace=78A69B9E-D624-466F-8D32-A66B0A999184 workspaces=1\n' "$WIN_A"
    [[ "$made" == "1" ]] && printf '  1: %s selected_workspace=960D1139-7458-4341-8C80-C6A04B0FF0C3 workspaces=0\n' "$WIN_B"
    exit 0 ;;
  new-window) echo 1 > "$ST/made_window"; printf 'OK\n' ;;
  current-window) [[ "$made" == "1" ]] && printf '%s\n' "$WIN_B" || printf '%s\n' "$WIN_A"; exit 0 ;;
  new-workspace) echo "$*" >> "$ST/new_ws_calls"; echo "OK workspace:90" ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:202 pane:9 workspace:90" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window newproj --working-directory /tmp/x --json 2>"$tmp/err.txt")
win=$(printf '%s' "$out" | jq -r '.window_ref // empty'); created=$(printf '%s' "$out" | jq -r '.created')
if [[ "$win" == "window:4" && "$created" == "true" ]]; then
  pass "name form with no match creates a new window and resolves its REF from the tree (created=true)"
else
  fail "name form with no match creates a new window" "win=$win created=$created err=$(cat "$tmp/err.txt")"
fi
if grep -q -- "new-workspace --name newproj" "$tmp/new_ws_calls" 2>/dev/null; then
  pass "new window gets a workspace titled <name> so future --window <name> finds it"
else
  fail "new window gets a titled workspace" "calls=$(cat "$tmp/new_ws_calls" 2>/dev/null || echo NONE)"
fi
if grep -q -- "--window window:4" "$tmp/create_calls" 2>/dev/null \
   && grep -q -- "--window window:4" "$tmp/new_ws_calls" 2>/dev/null; then
  pass "the workspace and surface are both created in the NEW window, not the focused one"
else
  fail "the workspace and surface are created in the new window" \
       "ws=$(cat "$tmp/new_ws_calls" 2>/dev/null) surf=$(cat "$tmp/create_calls" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case W3b: IDEMPOTENCE, end to end. Two calls for the same name against one
# stateful stub: the first creates the window, the second must REUSE it. This is
# the live failure the title-key bug produced — two calls for one name opened
# window:4 and window:5, each with its own correctly-titled workspace — and no
# single-call case can catch it, because each call was individually correct.
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
: > "$tmp/made_ws"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  tree)
    # WIN-B appears once new-window ran; its workspace carries a `title` once
    # new-workspace ran. Two separate bits of state, because the ref is resolved
    # between those two calls.
    if [[ -f "$ST/new_window_calls" ]]; then
      if [[ -s "$ST/made_ws" ]]; then
        printf '{"windows":[{"id":"WIN-A","ref":"window:1","index":0,"current":false,"workspaces":[]},{"id":"WIN-B","ref":"window:4","index":1,"current":true,"workspaces":[{"id":"WS-N","ref":"workspace:90","title":"%s","panes":[{"ref":"pane:1","index":0}]}]}]}\n' "$(cat "$ST/made_ws")"
      else
        printf '{"windows":[{"id":"WIN-A","ref":"window:1","index":0,"current":false,"workspaces":[]},{"id":"WIN-B","ref":"window:4","index":1,"current":true,"workspaces":[]}]}\n'
      fi
    else
      printf '{"windows":[{"id":"WIN-A","ref":"window:1","index":0,"current":true,"workspaces":[]}]}\n'
    fi ;;
  new-window) echo "$*" >> "$ST/new_window_calls"; printf 'OK\n' ;;
  current-window) printf 'WIN-B\n' ;;
  new-workspace)
    echo "$*" >> "$ST/new_ws_calls"
    printf '%s' "$3" > "$ST/made_ws"   # --name <text>
    echo "OK workspace:90" ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:205 pane:9 workspace:90" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
one=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window proj2 --json 2>"$tmp/err1.txt")
two=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window proj2 --json 2>"$tmp/err2.txt")
w1=$(printf '%s' "$one" | jq -r '.window_ref // empty'); c1=$(printf '%s' "$one" | jq -r '.created')
w2=$(printf '%s' "$two" | jq -r '.window_ref // empty'); c2=$(printf '%s' "$two" | jq -r '.created')
wins=$(grep -c . "$tmp/new_window_calls" 2>/dev/null || echo 0)
if [[ "$w1" == "window:4" && "$c1" == "true" && "$w2" == "window:4" && "$c2" == "false" && "$wins" -eq 1 ]]; then
  pass "a second --window <name> call reuses the window the first one created (one new-window)"
else
  fail "a second --window <name> call reuses the first window" \
       "first=$w1/$c1 second=$w2/$c2 new-window calls=$wins err=$(cat "$tmp/err2.txt")"
fi
rm -rf "$tmp"

# Case W4: the id diff comes back empty (a tree read that misses the new window),
# so the ref has to come from the UUID `cmux current-window` prints. new-window
# focuses what it creates, which is what makes that fallback sound.
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
WIN_B="440EF69F-1A97-41F2-A2FD-005D49AD7B87"
case "$1" in
  # The SAME tree before and after, so the before/after id diff is empty.
  tree)
    printf '{"windows":[{"id":"%s","ref":"window:4","index":1,"current":false,"workspaces":[]}]}\n' "$WIN_B" ;;
  new-window) printf 'OK\n' ;;
  # Lowercased on the way back, as a value that has been through another tool can be.
  current-window) printf '%s\n' "$(printf '%s' "$WIN_B" | tr 'A-Z' 'a-z')" ;;
  new-workspace) echo "$*" >> "$ST/new_ws_calls"; echo "OK workspace:91" ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:203 pane:9 workspace:91" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window newproj --json 2>"$tmp/err.txt")
win=$(printf '%s' "$out" | jq -r '.window_ref // empty')
if [[ "$win" == "window:4" ]]; then
  pass "an empty id diff falls back to the UUID current-window prints (case-insensitively)"
else
  fail "an empty id diff falls back to current-window's UUID" "win=$win err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# Case W5: nothing resolves the ref → HARD ERROR. Continuing with an empty
# --window would let cmux resolve the missing target to the FOCUSED window and
# land the callee in whatever the user is looking at.
tmp=$(mktemp -d /tmp/hotline-win-XXXXXX); mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  tree) printf '{"windows":[]}\n' ;;
  new-window) printf 'OK\n' ;;
  current-window) printf '\n' ;;
  new-workspace) echo "$*" >> "$ST/new_ws_calls"; echo "OK workspace:92" ;;
  new-surface) echo "$*" >> "$ST/create_calls"; echo "OK surface:204 pane:9 workspace:92" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
if PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" bash "$WIN" --window newproj --json >"$tmp/out.txt" 2>"$tmp/err.txt"; then
  fail "an unresolvable window ref is a hard error" "exited 0: out=$(cat "$tmp/out.txt")"
else
  if grep -q 'window ref could not be resolved' "$tmp/err.txt" \
     && [[ ! -f "$tmp/new_ws_calls" && ! -f "$tmp/create_calls" ]]; then
    pass "an unresolvable window ref exits non-zero and creates nothing in the focused window"
  else
    fail "an unresolvable window ref exits non-zero and creates nothing" \
         "err=$(cat "$tmp/err.txt") ws=$(cat "$tmp/new_ws_calls" 2>/dev/null) surf=$(cat "$tmp/create_calls" 2>/dev/null)"
  fi
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
