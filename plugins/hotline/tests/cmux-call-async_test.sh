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
# End-of-line anchor only — accepts any prefix (none / whitespace / `⏺ ` /
# future claude REPL chrome) without per-variant regex. "Latest match wins"
# combined with the EOL anchor handles all the rendering variants in one
# rule; quoted STATUS strings inside response prose almost never end a line.
latest_status() {
  awk '
    match($0, /STATUS: [A-Z_]+[[:space:]]*$/) {
      s=substr($0, RSTART); sub(/[[:space:]]*$/, "", s)
    }
    END {print s}
  '
}

# Response extraction — same loose-anchor logic. Resets buf on every
# WORK_IN_PROGRESS, saves on every terminal STATUS, emits the LAST saved
# buffer so multi-terminal-status screens use the most recent body.
extract_cmux_response() {
  grep -v "^bash /tmp/hotline-launch" \
    | grep -vE "^[╭│╰─└┌┘┐ℹ]" \
    | grep -vE "^>[[:space:]]*$" \
    | awk '
        /STATUS: WORK_IN_PROGRESS[[:space:]]*$/ {buf=""; next}
        /STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE)[[:space:]]*$/ {result=buf; buf=""; next}
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
# --detached targets the new-workspace placement explicitly (the default is now
# side-by-side, exercised in surface-placement_test.sh).
PATH="$tmp/bin:$PATH" bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" --prompt "hello" \
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
PATH="$tmp/bin:$PATH" bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" --prompt "hello" \
  > "$tmp/out.json" 2> "$tmp/stderr.txt"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "send failure exits after returning call_dir"
else
  fail "send failure exits after returning call_dir" "exit code: $rc"
fi
assert_async_error_contract "send failure" "$tmp"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# Default placement (side-by-side surface): the async launcher RESOLVES and
# calls cmux-cli's canonical open-side-surface.sh (single source of truth — no
# vendored copy), then writes surface_ref.txt (NOT workspace_ref.txt), defaults
# keep_workspace.txt=true, and sends the launch script to the SURFACE.
#
# We inject the opener via HOTLINE_OPEN_SIDE_SURFACE (a stub) so the test never
# depends on cmux-cli being installed. The side-by-side PTY-readiness gotcha is
# owned by cmux-cli's opener (and exercised at the unit level for the --window
# path in surface-placement_test.sh).
# ---------------------------------------------------------------------------

# Stub standing in for cmux-cli's open-side-surface.sh: records that it ran and
# emits the success JSON the launcher expects.
make_side_stub() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface invoked: $*" >> "${SIDE_STUB_LOG:?}"
printf '%s\n' '{"surface_ref":"surface:777","pane_ref":"pane:55","workspace_ref":"workspace:5","mode":"new-surface","ready":"ready"}'
EOF
  chmod +x "$1"
}

# Minimal cmux fake for the surface path: only send / read-screen / close-surface.
make_min_surface_cmux() {
  mkdir -p "$1"
  cat > "$1/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  send) echo "$*" >> "$ST/send_calls" ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  close-surface) echo "$*" >> "$ST/close_calls" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$1/cmux"
}

tmp=$(mktemp -d /tmp/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
make_side_stub "$tmp/open-side.sh"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello surface" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')

if grep -q "open-side-surface invoked:.*--wait-ready" "$tmp/side_log" 2>/dev/null; then
  pass "side-by-side async resolves and calls cmux-cli's opener with --wait-ready"
else
  fail "side-by-side async resolves and calls cmux-cli's opener with --wait-ready" \
       "side_log=$(cat "$tmp/side_log" 2>/dev/null || echo NONE) stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ -n "$call_dir" && -f "$call_dir/surface_ref.txt" && "$(cat "$call_dir/surface_ref.txt")" == "surface:777" ]]; then
  pass "side-by-side async writes surface_ref.txt (surface-mode signal)"
else
  fail "side-by-side async writes surface_ref.txt (surface-mode signal)" \
       "call_dir=$call_dir stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ -n "$call_dir" && ! -f "$call_dir/workspace_ref.txt" ]]; then
  pass "side-by-side async does NOT write workspace_ref.txt"
else
  fail "side-by-side async does NOT write workspace_ref.txt"
fi
if [[ -n "$call_dir" && "$(cat "$call_dir/pane_ref.txt" 2>/dev/null)" == "pane:55" ]]; then
  pass "side-by-side async records pane_ref.txt for PTY re-attach"
else
  fail "side-by-side async records pane_ref.txt" "got: $(cat "$call_dir/pane_ref.txt" 2>/dev/null)"
fi
if [[ -n "$call_dir" && "$(cat "$call_dir/keep_workspace.txt" 2>/dev/null)" == "true" ]]; then
  pass "side-by-side async keeps the surface (keep_workspace.txt=true)"
else
  fail "side-by-side async keeps the surface (keep_workspace.txt=true)" \
       "got: $(cat "$call_dir/keep_workspace.txt" 2>/dev/null)"
fi
if grep -q "send --surface surface:777 bash /tmp/hotline-launch" "$tmp/send_calls" 2>/dev/null; then
  pass "side-by-side async sends launch script to the surface"
else
  fail "side-by-side async sends launch script to the surface" \
       "send_calls=$(cat "$tmp/send_calls" 2>/dev/null)"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# Headless FALLBACK: cmux present but cmux-cli's opener not resolvable. The
# launcher must signal {"fallback":"headless"} (so the dial skill re-routes to
# the headless transport) and must NOT create a call_dir or any cmux surface.
tmp=$(mktemp -d /tmp/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd" "$tmp/empty"
# A cmux that records ANY invocation, so we can prove no side effects happened.
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${CMUX_FAKE_STATE:?}/cmux_calls"
case "$1" in
  new-workspace) echo "OK workspace:321" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
# HOTLINE_OPEN_SIDE_SURFACE points at a missing path AND HOTLINE_PLUGINS_DIR is
# empty, so the resolver can't find the real cmux-cli copy in this repo either.
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/nope.sh" HOTLINE_PLUGINS_DIR="$tmp/empty" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" 2>"$tmp/stderr.txt")
fb=$(printf '%s' "$out" | jq -r '.fallback // empty' 2>/dev/null)
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null)
if [[ "$fb" == "headless" && -z "$call_dir" ]]; then
  pass "missing opener signals {\"fallback\":\"headless\"} (no call_dir)"
else
  fail "missing opener signals fallback:headless" "out=$out stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ ! -f "$tmp/cmux_calls" ]]; then
  pass "headless fallback touches no cmux (no workspace/surface created)"
else
  fail "headless fallback touches no cmux" "cmux_calls=$(cat "$tmp/cmux_calls")"
fi
rm -rf "$tmp"

# --detached does NOT need the opener: even with NO opener resolvable, it must
# proceed on cmux (new-workspace), never signal headless fallback.
tmp=$(mktemp -d /tmp/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd" "$tmp/empty"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  new-workspace) echo "$*" >> "$ST/ws_calls"; echo "OK workspace:321" ;;
  read-screen) echo "$ " ;;
  send) echo "$*" >> "$ST/send_calls" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/nope.sh" HOTLINE_PLUGINS_DIR="$tmp/empty" \
  bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" --prompt "hello" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null)
fb=$(printf '%s' "$out" | jq -r '.fallback // empty' 2>/dev/null)
if [[ -z "$fb" && -n "$call_dir" && -f "$call_dir/workspace_ref.txt" ]]; then
  pass "--detached proceeds on cmux even with no opener (no headless fallback)"
else
  fail "--detached proceeds on cmux even with no opener" "fb=$fb call_dir=$call_dir"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# Surface readiness TIMEOUT: cmux-cli's opener exits 3 (no JSON) with the surface
# ref in its stderr. The launcher must close that orphan and write the async
# error contract — never leave a wedged surface behind.
tmp=$(mktemp -d /tmp/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
# Stub opener that mimics cmux-cli's --wait-ready timeout: exit 3, surface named
# in stderr, NO JSON on stdout.
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: --wait-ready timed out after 1s for surface:777 (pane:55)." >&2
exit 3
EOF
chmod +x "$tmp/open-side.sh"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if [[ -n "$call_dir" && -f "$call_dir/done" && -f "$call_dir/error.txt" ]]; then
  pass "side-by-side readiness timeout (opener exit 3) writes the async error contract"
else
  fail "side-by-side readiness timeout writes the async error contract" \
       "call_dir=$call_dir stderr=$(cat "$tmp/stderr.txt")"
fi
if grep -q "close-surface --surface surface:777" "$tmp/close_calls" 2>/dev/null; then
  pass "side-by-side readiness timeout closes the orphan surface parsed from stderr"
else
  fail "side-by-side readiness timeout closes the orphan surface" \
       "close_calls=$(cat "$tmp/close_calls" 2>/dev/null || echo NONE)"
fi
[[ -n "$call_dir" && ! -f "$call_dir/surface_ref.txt" ]] && \
  pass "side-by-side readiness timeout does NOT signal surface-mode to the wait scripts" || \
  fail "side-by-side readiness timeout does NOT signal surface-mode to the wait scripts"
rm -rf "$tmp" "$call_dir"

# --fork-session without --resume must hard-error (forking with no resume target
# silently creates an empty session — the bug this guard prevents).
fork_out=$(bash "$SCRIPT_UNDER_TEST" --cwd /tmp --prompt "hello" --fork-session 2>&1)
fork_rc=$?
if [[ $fork_rc -eq 1 ]] && printf '%s' "$fork_out" | grep -q "fork-session requires --resume"; then
  pass "--fork-session without --resume errors and exits 1"
else
  fail "--fork-session without --resume errors and exits 1" "rc=$fork_rc out=$fork_out"
fi

# --fork-session WITH --resume must pass the guard (no fork error emitted).
fork_ok_out=$(bash "$SCRIPT_UNDER_TEST" --cwd /tmp --prompt "hello" --fork-session --resume abc123 2>&1)
if printf '%s' "$fork_ok_out" | grep -q "fork-session requires --resume"; then
  fail "--fork-session with --resume passes the guard" "unexpected fork error: $fork_ok_out"
else
  pass "--fork-session with --resume passes the guard"
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
