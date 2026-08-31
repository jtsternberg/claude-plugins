#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-call.sh command construction without launching cmux.
#
# cmux-call.sh is the SYNCHRONOUS conference launcher. Like every other hotline
# path it now starts a BARE claude REPL and delivers the prompt with one
# `terminal.paste` over cmux's control socket, so the assertions about the prompt
# live on the socket REQUEST, and the launch script is asserted to be free of it
# (claude-plugins-92s5 — conference was the last path putting a whole payload on
# claude's argv, where `ps` publishes it to every local user).
#
# Two stub layers, because a socket write cannot be intercepted on PATH: `cmux`
# and `claude` are PATH stubs, and $CMUX_SOCKET_PATH points at the shared stub
# server in tests/lib/socket-stub-harness.sh.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
LAUNCH_SCRIPTS=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/cmux-call.sh"

# ---------------------------------------------------------------------------
# Poison stubs — same guard as cmux-call-async_test.sh. The header promises
# this suite never launches cmux, and nothing enforced it: an invocation that
# forgets its PATH="$tmp/bin:$PATH" prefix falls through to the real binaries.
# In the async sibling that opened a live `claude --resume abc123` pane on
# every test run. These sit at the FRONT of PATH so a missing stub fails loudly
# instead of escaping; a test's own fake prepends ahead of them and still wins.
# ---------------------------------------------------------------------------
POISON_BIN="$(mktemp -d)"
POISON_LOG="$POISON_BIN/violations"
for _poison in cmux claude; do
  cat > "$POISON_BIN/$_poison" <<POISON
#!/usr/bin/env bash
echo "$_poison \$*" >> "$POISON_LOG"
echo "TEST BUG: reached the real $_poison — this invocation is missing its PATH stub" >&2
exit 127
POISON
  chmod +x "$POISON_BIN/$_poison"
done
PATH="$POISON_BIN:$PATH"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_PYTHON3="$(command -v python3)"
if [[ -z "$REAL_PYTHON3" ]]; then
  echo "cmux-call: SKIP — python3 not available (the control-socket helper needs it)"
  exit 0
fi
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
SOCKROOT="$(mktemp -d)"
trap 'socket_stub_cleanup; rm -rf "$POISON_BIN" "$SOCKROOT"' EXIT
socket_stub_write_responses "$SOCKROOT/responses"
SOCK_ECHO="$SOCKROOT/typed.txt"; : > "$SOCK_ECHO"
OK_SOCK="$(socket_stub_start "$SOCKROOT/ok" "$SOCKROOT/responses/ok.json" "$SOCK_ECHO")"
OK_REQUESTS="$SOCKROOT/ok/requests.log"
export CMUX_SOCKET_PATH="$OK_SOCK"
export SOCK_ECHO_FILE="$SOCK_ECHO"
# Keep the confirmation polls short: no callee writes a transcript in this suite,
# so the transcript tier legitimately misses and the screen tier answers.
export HOTLINE_PASTE_CONFIRM_TRIES=2
export HOTLINE_PASTE_CONFIRM_SLEEP=0.05
export HOTLINE_PASTE_BOX_TIMEOUT=3

# The params of the LAST terminal.paste, decoded.
last_paste() {
  local field="${1:-text}"
  grep -F '"terminal.paste"' "$OK_REQUESTS" 2>/dev/null | tail -1 \
    | "$REAL_PYTHON3" -c '
import json,sys
line = sys.stdin.read().strip()
if not line: sys.exit(0)
if line.startswith("_cmux_capability_v1 "):
    line = line.split(" ", 2)[2]
print(json.loads(line)["params"].get(sys.argv[1], ""), end="")
' "$field" 2>/dev/null
}

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
    # surface-ready.sh's probe: echo the marker back twice (the typed line plus the
    # shell's output line), which is the >=2 hits it waits for. Without this the
    # detached path waits out its whole readiness budget on every case.
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$0.screen"; fi
    # Real cmux prints this on STDOUT. The stub must too, or a script that forgets
    # to capture it looks clean here and corrupts its JSON in production.
    echo "OK ${3:-workspace:123}"
    ;;
  read-screen)
    cat "$0.screen" 2>/dev/null
    # A booted REPL: the input box is a ❯ padded with a NO-BREAK SPACE. A plain
    # space is what a shell prompt draws, and delivery refuses to paste into that.
    printf 'Claude Code v2.1.226\n\xe2\x9d\xaf\xc2\xa0\n'
    # Whatever the socket stub echoed shows up too, as a pasted payload would —
    # but as N LITERAL LINES, where a real REPL collapses a submitted paste over
    # ~800 chars or 3 lines to a one-line `[Pasted text +N lines]`. Every stub in
    # this file shares that gap. Growing a payload fixture: claude-plugins-7u9g.
    [[ -n "${SOCK_ECHO_FILE:-}" && -f "$SOCK_ECHO_FILE" ]] && cat "$SOCK_ECHO_FILE"  # tripwire: claude-plugins-7u9g
    exit 0
    ;;
  tree)
    jq -nc '{windows:[{workspaces:[{id:"WS-UUID-123",ref:"workspace:123",
      panes:[{selected_surface_id:"SURF-UUID-123",
              surfaces:[{id:"SURF-UUID-123",ref:"surface:123"}]}]}]}]}'
    exit 0 ;;
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
  --prompt "/hotline:hotline-ringing [MODE: conference_call] [CALLER: /caller] [SESSION: abc] hello there" \
  > "$tmp/out.json" 2> "$tmp/stderr.txt"
rc=$?

if [[ $rc -eq 0 ]]; then
  pass "first-contact conference call exits successfully"
else
  fail "first-contact conference call exits successfully" "exit code: $rc stderr=$(cat "$tmp/stderr.txt")"
fi

# STDOUT IS EXACTLY ONE JSON OBJECT. `cmux send` prints "OK surface:N workspace:N",
# and an unredirected send prepended that to the payload — so every
# `jq -r '.session_id'` in dial.sh's conference branch came back empty. The suite's
# own `send` stub writes to a file, so only a real run showed it; this asserts the
# shape the caller actually depends on.
if jq -e . "$tmp/out.json" >/dev/null 2>&1; then
  pass "stdout is a single parseable JSON object (no leaked cmux chatter)"
else
  fail "stdout is a single parseable JSON object (no leaked cmux chatter)" \
       "got: $(cat "$tmp/out.json")"
fi

send_args=$(cat "$tmp/send_args" 2>/dev/null || true)
assert_contains "first-contact sends launch script" "$send_args" "send --workspace workspace:123 bash /tmp/hotline-cmux-launch-"
assert_contains "first-contact appends enter" "$send_args" "\\n"

launch_script=$(printf '%s' "$send_args" | sed -E 's/.*bash (\/tmp\/hotline-cmux-launch-[^\\[:space:]]+).*/\1/')
LAUNCH_SCRIPTS+=("$launch_script")
launch_body=$(cat "$launch_script" 2>/dev/null || true)
assert_contains "first-contact launch script runs claude" "$launch_body" "claude"
assert_contains "first-contact pre-sets session id" "$launch_body" "--session-id"
# THE PROMPT IS PASTED, NOT LAUNCHED (claude-plugins-92s5).
assert_contains "first-contact PASTES the conference prompt" "$(last_paste)" "/hotline:hotline-ringing"
assert_contains "first-contact preserves conference mode" "$(last_paste)" "conference_call"
assert_contains "first-contact pastes the message body" "$(last_paste)" "hello there"
assert_contains "the paste carries a [CALL_ID:] nonce after the slash command" \
  "$(last_paste)" "/hotline:hotline-ringing [CALL_ID: "
if printf '%s' "$launch_body" | grep -q 'hotline-ringing'; then
  fail "the prompt is NOT in the launch script" "got: $launch_body"
else
  pass "the prompt is NOT in the launch script"
fi
# No positional prompt means no `--` separator either; its presence would mean a
# prompt came back onto the argv.
if printf '%s' "$launch_body" | grep -qE -- "--allowedTools=.+ -- "; then
  fail "the launch line ends at --allowedTools, with no positional prompt" \
       "got: $launch_body"
else
  pass "the launch line ends at --allowedTools, with no positional prompt"
fi
cid=$(jq -r '.call_id // empty' "$tmp/out.json" 2>/dev/null || true)
if [[ "$cid" =~ ^[0-9a-f]{16}$ ]]; then
  pass "a conference call reports its call_id nonce"
else
  fail "a conference call reports its call_id nonce" "got: $cid"
fi

# Regression: --allowedTools must be `=`-joined into ONE argv word. cmux's
# checkpoint recorder treats the flag as an arity-0 boolean and drops the value
# that follows it in the two-token form, storing a restore command that ends in
# a bare `'--allowedTools'`; `cmux restore claude <id>` then dies after a cmux
# restart with "option '--allowedTools' argument missing". The `=` form is
# preserved byte-for-byte (verified on cmux 0.64.22).
if printf '%s' "$launch_body" | grep -q -- "--allowedTools="; then
  pass "launch script uses the =-joined --allowedTools form"
else
  fail "launch script uses the =-joined --allowedTools form" "got: $launch_body"
fi
if printf '%s' "$launch_body" | grep -qE -- "--allowedTools[[:space:]]"; then
  fail "launch script avoids the two-token --allowedTools form" "got: $launch_body"
else
  pass "launch script avoids the two-token --allowedTools form"
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
assert_contains "resume call PASTES the follow-up prompt" "$(last_paste)" "follow up message"

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

# --- Finding 4: registration happens BEFORE delivery -------------------------
# An undelivered conference used to leave a LIVE REPL that nothing had recorded:
# registration sat after the delivery gate, so the next dial to that workspace found
# no cached session, called it first contact, and opened a SECOND surface beside the
# abandoned one. Everything registration needs is known once the launch went out.
tmp=$(mktemp -d /tmp/hotline-cmux-call-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd" "$tmp/home"
# A socket that accepts nothing: delivery cannot be confirmed, so the script exits 1.
NODELIVER_SOCK="$(socket_stub_start "$SOCKROOT/nodeliver" "$SOCKROOT/responses/reject.json")"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  new-workspace) echo "OK workspace:123" ;;
  send)
    printf '%s' "$*" > "${CMUX_FAKE_STATE:?}/send_args"
    # See the first stub in this file: round-trips surface-ready.sh's probe marker.
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$0.screen"; fi
    echo "OK workspace:123" ;;
  read-screen)
    cat "$0.screen" 2>/dev/null
    printf 'Claude Code v2.1.226\n\xe2\x9d\xaf\xc2\xa0\n'; exit 0 ;;
  tree)
    jq -nc '{windows:[{workspaces:[{id:"WS-UUID-123",ref:"workspace:123",
      panes:[{selected_surface_id:"SURF-UUID-123",
              surfaces:[{id:"SURF-UUID-123",ref:"surface:123"}]}]}]}]}'
    exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out_undel=$(PATH="$tmp/bin:$PATH" HOME="$tmp/home" CMUX_FAKE_STATE="$tmp" \
  CMUX_SOCKET_PATH="$NODELIVER_SOCK" \
  bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" \
  --prompt "/hotline:hotline-ringing [MODE: conference_call] [SESSION: caller-reg] register me first" \
  2>"$tmp/stderr.txt")
rc=$?
if [[ $rc -ne 0 ]] && [[ "$(jq -r '.undelivered // false' <<<"$out_undel" 2>/dev/null)" == "true" ]]; then
  pass "an undelivered conference exits non-zero with undelivered:true"
else
  fail "an undelivered conference exits non-zero with undelivered:true" "rc=$rc out=$out_undel"
fi
REG_FILE="$tmp/home/.agents-hotline/sessions/caller-reg.json"
if [[ -s "$REG_FILE" ]] && jq -e '.connections | length > 0' "$REG_FILE" >/dev/null 2>&1; then
  pass "…and the session is STILL registered, so the next dial finds it"
else
  fail "…and the session is STILL registered, so the next dial finds it" \
       "$(ls -R "$tmp/home/.agents-hotline" 2>/dev/null || echo 'no registry')"
fi

# Finding 9: the undelivered prompt lives in a CALL DIR, in the shape every other
# path uses — not a bare /tmp/hotline-conf-prompt-* nothing GCs or knows about.
UNDEL_DIR=$(jq -r '.call_dir // empty' <<<"$out_undel" 2>/dev/null)
# The base is ${HOTLINE_CALL_HOME:-/tmp}: /tmp in production and for a direct run,
# a suite-owned scratch dir under run-all.sh (claude-plugins-cjgn). Assert the
# hotline-call-* shape under whichever base is active, not a hardcoded /tmp.
CALL_BASE="${HOTLINE_CALL_HOME:-/tmp}"
if [[ -n "$UNDEL_DIR" && -d "$UNDEL_DIR" && "$UNDEL_DIR" == "$CALL_BASE"/hotline-call-* ]]; then
  pass "the undelivered prompt is in a hotline-call-* dir, like every other path"
else
  fail "the undelivered prompt is in a hotline-call-* dir, like every other path" \
       "call_dir=$UNDEL_DIR base=$CALL_BASE"
fi
if [[ -s "$UNDEL_DIR/pending_paste.md" ]] \
   && grep -q 'register me first' "$UNDEL_DIR/pending_paste.md"; then
  pass "…named pending_paste.md, holding the prompt"
else
  fail "…named pending_paste.md, holding the prompt" "$(ls -A "$UNDEL_DIR" 2>/dev/null | tr '\n' ' ')"
fi
UNDEL_MODE=$(stat -c '%a' "$UNDEL_DIR/pending_paste.md" 2>/dev/null || stat -f '%Lp' "$UNDEL_DIR/pending_paste.md" 2>/dev/null)
if [[ "$UNDEL_MODE" == "600" ]]; then
  pass "…owner-only (0600)"
else
  fail "…owner-only (0600)" "mode=$UNDEL_MODE"
fi
if [[ -s "$UNDEL_DIR/call_id.txt" && -s "$UNDEL_DIR/cwd.txt" ]]; then
  pass "…with the call_id and cwd recovery tooling expects beside it"
else
  fail "…with the call_id and cwd recovery tooling expects beside it" \
       "$(ls -A "$UNDEL_DIR" 2>/dev/null | tr '\n' ' ')"
fi
# Scoped to THIS run: the old code left these behind on every failure, so a bare
# glob would report other runs' litter rather than this one's behavior. (There were
# four of them on this machine when the check was written — the finding was real.)
CONF_ORPHANS=$(find /tmp -maxdepth 1 -name 'hotline-conf-prompt-*' -newer "$SOCKROOT" 2>/dev/null)
if [[ -z "$CONF_ORPHANS" ]]; then
  pass "no bare /tmp/hotline-conf-prompt-* orphan is created"
else
  fail "no bare /tmp/hotline-conf-prompt-* orphan is created" "$CONF_ORPHANS"
fi
launch_script=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$tmp/send_args" 2>/dev/null | head -1)
[[ -n "$launch_script" ]] && LAUNCH_SCRIPTS+=("$launch_script")
rm -rf "$tmp" "$UNDEL_DIR"

# --- Finding 2: an opener that emits NO surface_id ---------------------------
# open-window-surface.sh never emits surface_id at all, and open-side-surface.sh
# emits null when its own tree lookup misses — so a conference that reads only
# .surface_id had nothing to paste into. Every --window conference failed here, and
# side placement failed nondeterministically. The delivery target must fall back to
# the display ref exactly as SEND_TARGET does; cmux-paste.sh resolves a ref through
# the tree. The other stubs in this file all emit a surface_id, which is why this
# needs its own.
tmp=$(mktemp -d /tmp/hotline-cmux-call-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "invoked: $*" >> "${SIDE_STUB_LOG:?}"
# No surface_id key, and a null one would behave identically.
printf '%s\n' '{"surface_ref":"surface:777","pane_ref":"pane:55","workspace_ref":"workspace:5","ready":"ready"}'
EOF
chmod +x "$tmp/open-side.sh"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  send) echo "$*" >> "$ST/send_calls"; echo "OK surface:777" ;;
  read-screen)
    printf 'Claude Code v2.1.226\n\xe2\x9d\xaf\xc2\xa0\n'
    # Literal lines, not a collapsed `[Pasted text +N lines]` — claude-plugins-7u9g.
    [[ -n "${SOCK_ECHO_FILE:-}" && -f "$SOCK_ECHO_FILE" ]] && cat "$SOCK_ECHO_FILE"  # tripwire: claude-plugins-7u9g
    exit 0 ;;
  tree)
    # The ref the opener DID give us resolves here to the pair the paste needs.
    jq -nc '{windows:[{workspaces:[{id:"WS-UUID-5",ref:"workspace:5",
      panes:[{surfaces:[{id:"SURFACE-UUID-777",ref:"surface:777"}]}]}]}]}'
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out_noid=$(env -u HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS \
  PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" \
  --prompt "/hotline:hotline-ringing [MODE: conference_call] [SESSION: abc] no surface id" 2>"$tmp/stderr.txt")
rc=$?
if [[ $rc -eq 0 ]] && jq -e . <<<"$out_noid" >/dev/null 2>&1; then
  pass "an opener that emits no surface_id still delivers (ref resolved via the tree)"
else
  fail "an opener that emits no surface_id still delivers (ref resolved via the tree)" \
       "rc=$rc out=$out_noid stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ "$(last_paste)" == *"no surface id"* ]]; then
  pass "…and the prompt reached the paste"
else
  fail "…and the prompt reached the paste" "pasted=$(last_paste)"
fi
if [[ "$(last_paste surface_id)" == "SURFACE-UUID-777" ]]; then
  pass "…addressed by the UUID the tree resolved from the display ref"
else
  fail "…addressed by the UUID the tree resolved from the display ref" "got: $(last_paste surface_id)"
fi
launch_script=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$tmp/send_calls" 2>/dev/null | head -1)
[[ -n "$launch_script" ]] && LAUNCH_SCRIPTS+=("$launch_script")
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
printf '%s\n' '{"surface_ref":"surface:777","surface_id":"SURFACE-UUID-777","pane_ref":"pane:55","pane_id":"PANE-UUID-55","workspace_ref":"workspace:5","ready":"ready"}'
EOF
chmod +x "$tmp/open-side.sh"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  send) echo "$*" >> "$ST/send_calls"; echo "OK surface:777" ;;
  read-screen)
    # A drawn input box: ❯ padded with a NO-BREAK SPACE, which is what delivery
    # requires before it will paste (a plain space is a shell prompt).
    printf 'Claude Code v2.1.226\n\xe2\x9d\xaf\xc2\xa0\n'
    # Literal lines, not a collapsed `[Pasted text +N lines]` — claude-plugins-7u9g.
    [[ -n "${SOCK_ECHO_FILE:-}" && -f "$SOCK_ECHO_FILE" ]] && cat "$SOCK_ECHO_FILE"  # tripwire: claude-plugins-7u9g
    exit 0 ;;
  tree)
    jq -nc '{windows:[{workspaces:[{id:"WS-UUID-5",ref:"workspace:5",
      panes:[{selected_surface_id:"SURFACE-UUID-777",
              surfaces:[{id:"SURFACE-UUID-777",ref:"surface:777"}]}]}]}]}'
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"

env -u HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS \
  PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" \
  --cwd "$tmp/cwd" --name "sbs test" \
  --prompt "/hotline:hotline-ringing [MODE: conference_call] [CALLER: /caller] [SESSION: abc] hi" \
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
  "$send_calls" "send --surface SURFACE-UUID-777 bash /tmp/hotline-cmux-launch-"

placement=$(jq -r '.placement // empty' "$tmp/out.json" 2>/dev/null || true)
surf_ref=$(jq -r '.surface_ref // empty' "$tmp/out.json" 2>/dev/null || true)
surf_id=$(jq -r '.surface_id // empty' "$tmp/out.json" 2>/dev/null || true)
ws_ref=$(jq -r '.workspace_ref // "null"' "$tmp/out.json" 2>/dev/null || true)
if [[ "$placement" == "surface" && "$surf_ref" == "surface:777" \
      && "$surf_id" == "SURFACE-UUID-777" && "$ws_ref" == "null" ]]; then
  pass "side-by-side reports display ref plus stable surface ID"
else
  fail "side-by-side reports display ref plus stable surface ID" \
       "placement=$placement surface_ref=$surf_ref surface_id=$surf_id workspace_ref=$ws_ref"
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

# ---------------------------------------------------------------------------
# Fork placement (conference transport). A fork writes to a NEW session id, so
# the resume target is not where the transcript lands and is not what we should
# report back as .session_id. cmux mode can't read the real id back from
# structured output, so the launcher must choose it via --session-id.
# Live-verified CLI rule: "--session-id can only be used with --continue or
# --resume if --fork-session is also specified."
# ---------------------------------------------------------------------------
tmpf=$(mktemp -d /tmp/hotline-cmux-fork-XXXXXX)
mkdir -p "$tmpf/bin" "$tmpf/cwd"
cat > "$tmpf/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  new-workspace) echo "OK workspace:123" ;;
  send)
    printf '%s' "$*" > "${CMUX_FAKE_STATE:?}/send_args"
    # See the first stub in this file: round-trips surface-ready.sh's probe marker.
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$0.screen"; fi
    echo "OK workspace:123" ;;
  read-screen)
    cat "$0.screen" 2>/dev/null
    printf 'Claude Code v2.1.226\n\xe2\x9d\xaf\xc2\xa0\n'
    # Literal lines, not a collapsed `[Pasted text +N lines]` — claude-plugins-7u9g.
    [[ -n "${SOCK_ECHO_FILE:-}" && -f "$SOCK_ECHO_FILE" ]] && cat "$SOCK_ECHO_FILE"  # tripwire: claude-plugins-7u9g
    exit 0 ;;
  tree)
    jq -nc '{windows:[{workspaces:[{id:"WS-UUID-123",ref:"workspace:123",
      panes:[{selected_surface_id:"SURF-UUID-123",
              surfaces:[{id:"SURF-UUID-123",ref:"surface:123"}]}]}]}]}'
    exit 0 ;;
esac
EOF
chmod +x "$tmpf/bin/cmux"

FORK_TARGET="11111111-2222-3333-4444-555555555555"
PATH="$tmpf/bin:$PATH" CMUX_FAKE_STATE="$tmpf" bash "$SCRIPT_UNDER_TEST" \
  --detached --cwd "$tmpf/cwd" --resume "$FORK_TARGET" --fork-session \
  --prompt "fork me" > "$tmpf/out.json" 2> "$tmpf/stderr.txt"

fork_send=$(cat "$tmpf/send_args" 2>/dev/null || true)
fork_ls=$(printf '%s' "$fork_send" | sed -E 's/.*bash (\/tmp\/hotline-cmux-launch-[^\\[:space:]]+).*/\1/')
LAUNCH_SCRIPTS+=("$fork_ls")
fork_body=$(cat "$fork_ls" 2>/dev/null || true)
fork_sid=$(jq -r '.session_id' "$tmpf/out.json" 2>/dev/null || true)

assert_contains "fork keeps --resume" "$fork_body" "--resume"
assert_contains "fork keeps --fork-session" "$fork_body" "--fork-session"
assert_contains "fork passes --session-id" "$fork_body" "--session-id"

if [[ "$fork_sid" != "$FORK_TARGET" && "$fork_sid" =~ ^[0-9a-f-]{36}$ ]]; then
  pass "fork returns the NEW forked session id, not the resume target"
else
  fail "fork returns the NEW forked session id, not the resume target" "got: $fork_sid"
fi

if printf '%s' "$fork_body" | grep -q -- "--session-id $fork_sid"; then
  pass "fork's reported session id matches the id handed to claude"
else
  fail "fork's reported session id matches the id handed to claude" \
       "sid=$fork_sid body=$fork_body"
fi
rm -rf "$tmpf"

# The whole point of the poison stubs: a leak is a test failure, not a stray pane.
if [[ -s "$POISON_LOG" ]]; then
  fail "no test reaches the real cmux or claude" "$(cat "$POISON_LOG")"
else
  pass "no test reaches the real cmux or claude"
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
