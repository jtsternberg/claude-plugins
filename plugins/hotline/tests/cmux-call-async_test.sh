#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-call-async.sh logic that can be exercised without
# launching cmux or Claude.
# =============================================================================
set -u
# Keep standalone runs under the system temp directory while honoring the runner.
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT=${TMP_ROOT%/}
export TMP_ROOT
PASS=0
FAIL=0
FAILED_CASES=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/cmux-call-async.sh"

# ---------------------------------------------------------------------------
# Poison stubs: the header promises this suite never launches cmux or Claude,
# and nothing enforced it. Every invocation below is supposed to carry its own
# PATH="$tmp/bin:$PATH" prefix; one of them didn't, ran on into the REAL cmux,
# and opened a live pane running `claude --resume abc123` on every single test
# run — cluttering the user's cmux and writing junk session transcripts into
# ~/.claude/projects/.
#
# These sit at the FRONT of PATH for the whole file, so a missing stub now
# fails loudly instead of escaping. Tests that install their own fake prepend
# ahead of these and still win.
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
trap 'rm -rf "$POISON_BIN"' EXIT

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

# Shape mirror of the launch line cmux-call-async.sh writes, for the quoting
# assertions below. NO PROMPT: production launches a bare claude REPL and pastes
# the prompt in afterwards, and the real script's output is asserted directly
# further down so this mirror cannot quietly drift away from it.
build_launch_script() {
  local resume_id="$1"
  local session_id_preset="$2"
  local fork_session="$3"
  local session_name="$4"
  local allowed_tools="$5"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'claude'
    [[ -n "$resume_id" ]] && printf ' --resume %q' "$resume_id"
    [[ -z "$resume_id" && -n "$session_id_preset" ]] && \
      printf ' --session-id %q' "$session_id_preset"
    $fork_session && printf ' --fork-session'
    [[ -n "$session_name" ]] && printf ' -n %q' "$session_name"
    # Mirrors production: `=`-joined single argv word (see cmux-call-async.sh).
    printf ' --allowedTools=%q\n' "$allowed_tools"
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

script=$(build_launch_script "" "11111111-1111-4111-8111-111111111111" false "hotline test" "Bash(git *) Edit")
ERR_FILE="${TMPDIR:-/tmp}/hotline-cmux-test.err"
if printf '%s' "$script" | bash -n 2> "$ERR_FILE"; then
  pass "launch script quotes complex --tools specs"
else
  fail "launch script quotes complex --tools specs" "$(cat "$ERR_FILE")"
fi
rm -f "$ERR_FILE"

script=$(build_launch_script "" "22222222-2222-4222-8222-222222222222" false "name" "Bash Read")

# Regression: --allowedTools must be `=`-joined into ONE argv word. cmux's
# checkpoint recorder treats the flag as an arity-0 boolean and drops the value
# that follows it in the two-token form, storing a restore command that ends in
# a bare `'--allowedTools'`; `cmux restore claude <id>` then dies after a cmux
# restart with "option '--allowedTools' argument missing". The `=` form is
# preserved byte-for-byte (verified on cmux 0.64.22).
if printf '%s' "$script" | grep -q -- "--allowedTools="; then
  pass "launch script uses the =-joined --allowedTools form"
else
  fail "launch script uses the =-joined --allowedTools form" "got: $script"
fi
if printf '%s' "$script" | grep -qE -- "--allowedTools[[:space:]]"; then
  fail "launch script avoids the two-token --allowedTools form" "got: $script"
else
  pass "launch script avoids the two-token --allowedTools form"
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

tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
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

tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
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
  # Every send fails here, including the readiness probe — which is not what this
  # case is testing, so the caller caps HOTLINE_SURFACE_READY_TIMEOUT rather than
  # waiting out the real budget.
esac
EOF
chmod +x "$tmp/bin/cmux"
PATH="$tmp/bin:$PATH" HOTLINE_SURFACE_READY_TIMEOUT=1 \
  bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" --prompt "hello" \
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
printf '%s\n' '{"surface_ref":"surface:777","surface_id":"SURFACE-UUID-777","pane_ref":"pane:55","pane_id":"PANE-UUID-55","workspace_ref":"workspace:5","mode":"new-surface","ready":"ready"}'
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
  # Closing a surface needs --workspace as well as --surface, and only the tree
  # knows which workspace — so a stub that records close calls has to answer
  # `tree` too, or the close never gets as far as being recorded.
  # CMUX_FAKE_NO_TREE models a cmux whose tree cannot be read.
  tree)  [[ -n "${CMUX_FAKE_NO_TREE:-}" ]] && exit 1
         jq -nc '{windows:[{workspaces:[{id:"WORKSPACE-UUID-5",ref:"workspace:5",
           panes:[{selected_surface_id:"SURFACE-UUID-777",
                   surfaces:[{id:"SURFACE-UUID-777",ref:"surface:777"}]}]}]}]}' ;;
  close-surface) echo "$*" >> "$ST/close_calls" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$1/cmux"
}

tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
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
if grep -q -- '--wait-ready-timeout 30' "$tmp/side_log"; then
  pass "side-by-side async passes the 30-second default"
else
  fail "side-by-side async passes the 30-second default" "$(cat "$tmp/side_log")"
fi
cp "$tmp/send_calls" "$tmp/send_calls.original"
out_override=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" HOTLINE_SURFACE_READY_TIMEOUT=12 \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt override 2>"$tmp/override.err")
override_dir=$(printf '%s' "$out_override" | jq -r '.call_dir // empty')
if grep -q -- '--wait-ready-timeout 12' "$tmp/side_log" && [[ -f "$override_dir/surface_ref.txt" ]]; then
  pass "side-by-side async passes override to opener"
else
  fail "side-by-side async passes override to opener" "$(cat "$tmp/side_log")"
fi
[[ -f "$override_dir/launch_script.txt" ]] && rm -f "$(cat "$override_dir/launch_script.txt")"
rm -rf "$override_dir"
cp "$tmp/send_calls.original" "$tmp/send_calls"
if [[ -n "$call_dir" && -f "$call_dir/surface_ref.txt" && "$(cat "$call_dir/surface_ref.txt")" == "SURFACE-UUID-777" ]]; then
  pass "side-by-side async writes stable surface UUID handle"
else
  fail "side-by-side async writes stable surface UUID handle" \
       "call_dir=$call_dir stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ -n "$call_dir" && ! -f "$call_dir/workspace_ref.txt" ]]; then
  pass "side-by-side async does NOT write workspace_ref.txt"
else
  fail "side-by-side async does NOT write workspace_ref.txt"
fi
if [[ -n "$call_dir" && "$(cat "$call_dir/pane_ref.txt" 2>/dev/null)" == "PANE-UUID-55" ]]; then
  pass "side-by-side async records stable pane UUID (for diagnosis, not re-attach)"
else
  fail "side-by-side async records stable pane UUID" "got: $(cat "$call_dir/pane_ref.txt" 2>/dev/null)"
fi
if [[ -n "$call_dir" && "$(cat "$call_dir/keep_workspace.txt" 2>/dev/null)" == "true" ]]; then
  pass "side-by-side async keeps the surface (keep_workspace.txt=true)"
else
  fail "side-by-side async keeps the surface (keep_workspace.txt=true)" \
       "got: $(cat "$call_dir/keep_workspace.txt" 2>/dev/null)"
fi
if grep -q "send --surface SURFACE-UUID-777 bash /tmp/hotline-launch" "$tmp/send_calls" 2>/dev/null; then
  pass "side-by-side async sends launch script by stable surface UUID"
else
  fail "side-by-side async sends launch script by stable surface UUID" \
       "send_calls=$(cat "$tmp/send_calls" 2>/dev/null)"
fi
# ONE launch command, not two. Counted on the launch line specifically, because the
# send is now preceded by a Ctrl-U: the surface's input line is shared with the
# user, and on 2026-08-26 three of their keystrokes arrived first, so the shell ran
# `rkebash /tmp/hotline-launch-…` and the caller burned its whole 60s boot budget
# (claude-plugins-r465.7). A second LAUNCH send would still be a double-boot.
if [[ "$(grep -c '^send .*bash /tmp/hotline-launch' "$tmp/send_calls" 2>/dev/null || true)" -eq 1 ]]; then
  pass "first-contact launch script is delivered exactly once"
else
  fail "first-contact launch script is delivered exactly once" \
       "send_calls=$(cat "$tmp/send_calls" 2>/dev/null)"
fi
# The Ctrl-U itself: the raw 0x15 byte through the TEXT path, addressed to the SAME
# handle as the launch. `send-key ctrl+u` would not reach the shell, and an
# unaddressed send would land in whatever surface the user is looking at.
# -a: the log holds a raw 0x15 byte, which GNU grep would call binary content.
if grep -aq $'^send --surface SURFACE-UUID-777 \025$' "$tmp/send_calls" 2>/dev/null; then
  pass "the launch line is cleared with a Ctrl-U on the same handle first"
else
  fail "the launch line is cleared with a Ctrl-U on the same handle first" \
       "send_calls=$(cat "$tmp/send_calls" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# THE PROMPT IS NOT IN THE LAUNCH. Asserted against the launch script the real
# run just wrote, not a mirror of it.
#
# First contact used to run `claude "<ringing-wrapped prompt>"`, putting whole
# work orders in an argv readable by any local user through `ps`
# (claude-plugins-86ka). Now the REPL comes up bare and the prompt waits in
# pending_paste.md for the same terminal.paste every follow-up uses.
# ---------------------------------------------------------------------------
LAUNCH_BODY=""
[[ -f "$call_dir/launch_script.txt" ]] && \
  LAUNCH_BODY="$(cat "$(cat "$call_dir/launch_script.txt")" 2>/dev/null)"

if [[ -n "$LAUNCH_BODY" ]] && ! printf '%s' "$LAUNCH_BODY" | grep -qF 'hello surface'; then
  pass "the prompt is NOT in the launch script"
else
  fail "the prompt is NOT in the launch script" "launch: $LAUNCH_BODY"
fi
# No positional prompt means no `--` separator either. Its presence would mean a
# prompt came back.
if printf '%s' "$LAUNCH_BODY" | grep -qE -- '--allowedTools=.* -- '; then
  fail "the launch line ends at --allowedTools, with no positional prompt" "launch: $LAUNCH_BODY"
else
  pass "the launch line ends at --allowedTools, with no positional prompt"
fi
if printf '%s' "$LAUNCH_BODY" | grep -q 'claude'; then
  pass "the launch script still starts a claude REPL"
else
  fail "the launch script still starts a claude REPL" "launch: $LAUNCH_BODY"
fi

if [[ -s "$call_dir/pending_paste.md" ]]; then
  pass "the prompt waits in pending_paste.md for delivery"
else
  fail "the prompt waits in pending_paste.md for delivery" "call_dir=$call_dir"
fi
PENDING_MODE=$(stat -c '%a' "$call_dir/pending_paste.md" 2>/dev/null \
  || stat -f '%Lp' "$call_dir/pending_paste.md" 2>/dev/null)
if [[ "$PENDING_MODE" == "600" ]]; then
  pass "pending_paste.md is owner-only (0600)"
else
  fail "pending_paste.md is owner-only (0600)" "mode=$PENDING_MODE"
fi
PENDING_BODY="$(cat "$call_dir/pending_paste.md" 2>/dev/null)"
if [[ "$PENDING_BODY" == *"hello surface"* ]]; then
  pass "pending_paste.md holds the prompt verbatim"
else
  fail "pending_paste.md holds the prompt verbatim" "got: $PENDING_BODY"
fi

[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# A slash-command prompt keeps the nonce AFTER the command token, on the same
# line — the shape the ringing skill parses. claude only recognises a slash
# command at the very start of the input, so a leading header line would turn the
# whole ringing invocation into plain text.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
make_side_stub "$tmp/open-side.sh"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" \
  --prompt "/hotline:hotline-ringing [MODE: work_order] do the thing" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
RING_BODY="$(cat "$call_dir/pending_paste.md" 2>/dev/null)"
if [[ "$RING_BODY" == '/hotline:hotline-ringing [CALL_ID: '*'] [MODE: work_order] do the thing' ]]; then
  pass "a slash-command prompt keeps the nonce after the command token"
else
  fail "a slash-command prompt keeps the nonce after the command token" "got: $RING_BODY"
fi
if [[ "$(cat "$call_dir/mode.txt" 2>/dev/null)" == "work_order" ]]; then
  pass "the ringing tags are still parsed for the call registry"
else
  fail "the ringing tags are still parsed for the call registry" \
       "mode.txt=$(cat "$call_dir/mode.txt" 2>/dev/null)"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# --prompt-file is the argv-free entry point dial.sh uses.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
make_side_stub "$tmp/open-side.sh"
printf 'work order from a file\nwith a second line' > "$tmp/prompt.txt"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt-file "$tmp/prompt.txt" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if [[ "$(cat "$call_dir/pending_paste.md" 2>/dev/null)" == *"work order from a file"$'\n'"with a second line" ]]; then
  pass "--prompt-file lands the same bytes in pending_paste.md"
else
  fail "--prompt-file lands the same bytes in pending_paste.md" \
       "got: $(cat "$call_dir/pending_paste.md" 2>/dev/null)"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

out=$(bash "$SCRIPT_UNDER_TEST" --cwd /tmp --prompt-file "/tmp/definitely-not-here-$$" 2>&1)
if [[ "$out" == *'"error"'* && "$out" == *"does not exist"* ]]; then
  pass "a missing --prompt-file is an error, not an empty prompt"
else
  fail "a missing --prompt-file is an error, not an empty prompt" "out: $out"
fi

# Headless FALLBACK: cmux present but cmux-cli's opener not resolvable. The
# launcher must signal {"fallback":"headless"} (so the dial skill re-routes to
# the headless transport) and must NOT create a call_dir or any cmux surface.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
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
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd" "$tmp/empty"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  new-workspace) echo "$*" >> "$ST/ws_calls"; echo "OK workspace:321" ;;
  # Round-trips surface-ready.sh's probe marker — the typed line plus the shell's
  # output line, which is the >=2 hits the probe waits for. Without it the detached
  # path waits out its whole readiness budget on every case.
  read-screen) cat "$ST/screen.txt" 2>/dev/null; echo "$ " ;;
  send)
    echo "$*" >> "$ST/send_calls"
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
    ;;
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
# This stub answers no `tree`, so the surface inside the new workspace cannot be
# resolved — which must cost the call NOTHING beyond a follow-up's reuse. The
# workspace and its PTY are already up; failing the dial over an unreadable tree
# would turn a degraded follow-up into a dead call (claude-plugins-zaus).
if [[ -n "$call_dir" && ! -f "$call_dir/error.txt" && ! -f "$call_dir/surface_ref.txt" ]]; then
  pass "…and an unresolvable surface leaves the call intact, just without a reuse handle"
else
  fail "…and an unresolvable surface leaves the call intact, just without a reuse handle" \
       "error=$(cat "$call_dir/error.txt" 2>/dev/null) surface=$(cat "$call_dir/surface_ref.txt" 2>/dev/null)"
fi
if grep -q "could not resolve the surface inside detached workspace workspace:321" \
     "$call_dir/surface_err.txt" 2>/dev/null; then
  pass "…saying so in surface_err.txt rather than silently"
else
  fail "…saying so in surface_err.txt rather than silently" \
       "surface_err=$(cat "$call_dir/surface_err.txt" 2>/dev/null || echo NONE)"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# ---------------------------------------------------------------------------
# --detached records the surface its callee actually lives in (claude-plugins-zaus).
#
# A detached placement opens a workspace tab holding exactly one surface, and the
# launcher used to record only the workspace. So the session cache learned no
# surface, and every follow-up reported `surface-reuse-skipped(no-cached-surface)`
# and opened another tab with the callee still mid-conversation in the first.
#
# Resolved AFTER `new-workspace` returns and taken as a UUID, never as the
# positional `surface:N` the same tree entry carries: a ref names whatever sits in
# slot N, and slots renumber before the follow-up that reads this handle.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
: > "$tmp/screen.txt"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  new-workspace) echo "$*" >> "$ST/ws_calls"; echo "OK workspace:321" ;;
  read-screen)   cat "$ST/screen.txt" 2>/dev/null; echo "$ " ;;
  send)
    echo "$*" >> "$ST/send_calls"
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
    ;;
  tree)          echo "$*" >> "$ST/tree_calls"
                 jq -nc '{windows:[{workspaces:[{id:"WORKSPACE-UUID-321",ref:"workspace:321",
                   panes:[{selected_surface_id:"SURFACE-UUID-321",
                           surfaces:[{id:"SURFACE-UUID-321",ref:"surface:901"}]}]}]}]}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" --label "probe" --prompt "hello" \
  2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty' 2>/dev/null)
if [[ "$(cat "$call_dir/surface_ref.txt" 2>/dev/null)" == "SURFACE-UUID-321" ]]; then
  pass "--detached records the surface inside its new workspace, by UUID"
else
  fail "--detached records the surface inside its new workspace, by UUID" \
       "got: $(cat "$call_dir/surface_ref.txt" 2>/dev/null || echo NONE)"
fi
if [[ "$(cat "$call_dir/workspace_id.txt" 2>/dev/null)" == "WORKSPACE-UUID-321" \
   && "$(cat "$call_dir/workspace_ref.txt" 2>/dev/null)" == "workspace:321" ]]; then
  pass "…and the workspace both ways: the ref it sends to, the UUID a close scopes with"
else
  fail "…and the workspace both ways: the ref it sends to, the UUID a close scopes with" \
       "ref=$(cat "$call_dir/workspace_ref.txt" 2>/dev/null) id=$(cat "$call_dir/workspace_id.txt" 2>/dev/null)"
fi
# placement.txt is what keeps the waiters polling and CLOSING the workspace: a
# detached tab auto-closes on completion, and cmux cannot close the last surface
# in a workspace, so inferring surface mode from the handle above would leave the
# tab open forever.
if [[ "$(cat "$call_dir/placement.txt" 2>/dev/null)" == "detached" ]]; then
  pass "…and placement.txt still names this a DETACHED call"
else
  fail "…and placement.txt still names this a DETACHED call" \
       "got: $(cat "$call_dir/placement.txt" 2>/dev/null || echo NONE)"
fi
# --id-format both or every `.id` comes back null, and the handle above is then
# unwritable — the guard in docs/compounding.md's pin-the-container entry.
if grep -q -- '--id-format both' "$tmp/tree_calls" 2>/dev/null; then
  pass "…enumerating with --id-format both, without which every .id is null"
else
  fail "…enumerating with --id-format both, without which every .id is null" \
       "tree_calls=$(cat "$tmp/tree_calls" 2>/dev/null || echo NONE)"
fi
# The launch still goes to the WORKSPACE, not the surface: the workspace ref is
# the send target the detached path has always used and the one the boot wait polls.
if grep -q "send --workspace workspace:321 bash /tmp/hotline-launch" "$tmp/send_calls" 2>/dev/null; then
  pass "…and the launch command still addresses the workspace"
else
  fail "…and the launch command still addresses the workspace" \
       "send_calls=$(cat "$tmp/send_calls" 2>/dev/null)"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# Explicit ownership permits retry only after the opener reports cleanup failure.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"; : > "$tmp/screen.txt"; make_min_surface_cmux "$tmp/bin"
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "  owned_cleanup_failed surface_id=EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE workspace_id=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB pane_id=DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD" >&2
exit 3
EOF
chmod +x "$tmp/open-side.sh"
cp "$(dirname "$SCRIPT_UNDER_TEST")/../../../../cmux-cli/skills/using-cmux-cli/scripts/bounded-command.py" "$tmp/bounded-command.py"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt hi)
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if grep -q 'close-surface --workspace BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB --surface EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE --force' "$tmp/close_calls"; then
  pass "explicit failed cleanup retries owned UUID without tree lookup"
else
  fail "explicit failed cleanup retries owned UUID without tree lookup" "$(cat "$tmp/close_calls" 2>/dev/null)"
fi
rm -rf "$call_dir"
# Simulate the bounded helper timing out, without a real sleep or cmux process.
printf 'import sys\nsys.exit(124)\n' > "$tmp/bounded-command.py"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt hi)
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if grep -q 'failed to close the owned orphan surface' "$call_dir/surface_err.txt"; then
  pass "timed out owned cleanup retry records failure"
else
  fail "timed out owned cleanup retry records failure" "$(cat "$call_dir/surface_err.txt" 2>/dev/null)"
fi
rm -rf "$tmp" "$call_dir"

# Surface readiness TIMEOUT: cmux-cli's opener exits 3 (no JSON) with the surface
# ref in its stderr. The launcher must close that orphan and write the async
# error contract — never leave a wedged surface behind.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
# Stub opener that mimics cmux-cli's --wait-ready timeout: exit 3, surface named
# in stderr, NO JSON on stdout.
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: --wait-ready timed out after 1s for surface:777 (pane:55)." >&2
echo "  surface_id=SURFACE-UUID-777 workspace_id=WORKSPACE-UUID-5 pane_id=PANE-UUID-55" >&2
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
# THE CONTAINER IS NOT OPTIONAL: `cmux close-surface --surface <handle>` resolves
# inside the caller's inherited workspace context and answers "Surface not found"
# out of it, so the close that only ever passed --surface silently no-op'd and
# leaked the surface it meant to reap (claude-plugins-5k43). Both halves are the
# UUIDs the tree reported — the positional surface:777 out of the opener's stderr
# is only what starts the lookup.
if [[ ! -s "$tmp/close_calls" ]]; then
  pass "old opener diagnostic does not prove ownership and is not reaped"
else
  fail "old opener diagnostic does not prove ownership and is not reaped" "close_calls=$(cat "$tmp/close_calls")"
fi
# The call FAILED before a placement was settled, so the dir names no cmux host at
# all and the waiters take the file-watch path that reports the launcher's own
# error.txt. placement.txt is what carries that now; surface_ref.txt used to.
if [[ -n "$call_dir" && ! -f "$call_dir/placement.txt" && ! -f "$call_dir/surface_ref.txt" ]]; then
  pass "side-by-side readiness timeout names no placement to the wait scripts"
else
  fail "side-by-side readiness timeout names no placement to the wait scripts" \
       "placement=$(cat "$call_dir/placement.txt" 2>/dev/null || echo NONE)"
fi
rm -rf "$tmp" "$call_dir"

# A close cmux REFUSES is recorded, not swallowed. Same fixture with an unreadable
# tree: the workspace cannot be resolved, so the close cannot be made — and the
# whole point of claude-plugins-5k43 is that this leaves a diagnostic behind.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: --wait-ready timed out after 1s for surface:777 (pane:55)." >&2
echo "  surface_id=SURFACE-UUID-777 workspace_id=WORKSPACE-UUID-5 pane_id=PANE-UUID-55" >&2
exit 3
EOF
chmod +x "$tmp/open-side.sh"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" CMUX_FAKE_NO_TREE=1 \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if grep -q "NOT reaping orphan surface surface:777" "$call_dir/surface_err.txt" 2>/dev/null; then
  pass "old opener refusal is recorded in surface_err.txt"
else
  fail "old opener refusal is recorded in surface_err.txt" \
       "surface_err=$(cat "$call_dir/surface_err.txt" 2>/dev/null || echo NONE)"
fi
if [[ ! -s "$tmp/close_calls" ]]; then
  pass "…and no unscoped close-surface was attempted as a fallback"
else
  fail "…and no unscoped close-surface was attempted as a fallback" \
       "close_calls=$(cat "$tmp/close_calls")"
fi
rm -rf "$tmp" "$call_dir"

# AN OPENER THAT NAMES THE ORPHAN ONLY BY POSITIONAL REF IS NOT REAPED. Resolving
# `surface:777` through the tree does not make the ref correct — it closes
# whatever occupies slot 777 now, and the readiness probe is a window (8s by
# default) in which a sibling closing renumbers it onto a live tab. The old
# unscoped close merely no-op'd here; a scoped one would succeed on the wrong
# surface. So the skip is recorded and nothing is closed.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
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
if grep -q "NOT reaping orphan surface surface:777" "$call_dir/surface_err.txt" 2>/dev/null; then
  pass "a ref-only orphan is NOT reaped, and the skip is recorded in surface_err.txt"
else
  fail "a ref-only orphan is NOT reaped, and the skip is recorded in surface_err.txt" \
       "surface_err=$(cat "$call_dir/surface_err.txt" 2>/dev/null || echo NONE)"
fi
if [[ ! -s "$tmp/close_calls" ]]; then
  pass "…and no close-surface went out at all, scoped or otherwise"
else
  fail "…and no close-surface went out at all, scoped or otherwise" \
       "close_calls=$(cat "$tmp/close_calls")"
fi
rm -rf "$tmp" "$call_dir"

# Caller-context resolution failure: cmux-cli's opener exits 2 because it can't
# resolve the CALLER's own pane/workspace from `cmux identify` (freshly moved or
# spawned caller surface, not yet re-registered). The launcher must NOT fail the
# whole call — it degrades to detached placement so the dial still completes.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
# Fake cmux that supports the detached path (new-workspace + read-screen + send).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  new-workspace) echo "OK workspace:456" ;;
  # See above: the probe marker is echoed back so readiness succeeds.
  read-screen)   cat "$ST/screen.txt" 2>/dev/null; echo "$ " ;;
  send)
    echo "$*" >> "$ST/send_calls"
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$ST/screen.txt"; fi
    ;;
  # The detached path resolves the surface inside the workspace it just opened,
  # so the stub has to answer `tree` — with `.id` UUIDs, which cmux only reports
  # under --id-format both.
  tree)          jq -nc '{windows:[{workspaces:[{id:"WORKSPACE-UUID-456",ref:"workspace:456",
                   panes:[{selected_surface_id:"SURFACE-UUID-456",
                           surfaces:[{id:"SURFACE-UUID-456",ref:"surface:900"}]}]}]}]}' ;;
  close-surface) echo "$*" >> "$ST/close_calls" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/cmux"
# Opener stub mimicking open-side-surface's caller-resolution failure: exit 2
# with the identify diagnostic on stderr, NO JSON on stdout.
cat > "$tmp/open-side.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: could not resolve caller.pane_ref / workspace_ref from identify (retried 5×; caller surface not registered?)" >&2
exit 2
EOF
chmod +x "$tmp/open-side.sh"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if [[ -n "$call_dir" && ! -f "$call_dir/error.txt" ]]; then
  pass "caller-resolution failure does NOT fail the call (degrades to detached)"
else
  fail "caller-resolution failure does NOT fail the call" \
       "call_dir=$call_dir error=$(cat "$call_dir/error.txt" 2>/dev/null) stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ -n "$call_dir" && "$(cat "$call_dir/workspace_ref.txt" 2>/dev/null)" == "workspace:456" ]]; then
  pass "caller-resolution fallback lands in detached workspace (workspace_ref.txt)"
else
  fail "caller-resolution fallback lands in detached workspace" \
       "got: $(cat "$call_dir/workspace_ref.txt" 2>/dev/null)"
fi
# THE DEGRADE IS NAMED, not inferred from a missing file. dial.sh used to read
# `workspace_ref.txt && ! surface_ref.txt` as the degrade signal, which meant a
# detached callee could not record the surface a follow-up needs without silencing
# the fallback (claude-plugins-zaus). degraded.txt carries it now, and
# placement.txt says which host the waiters poll and close.
if [[ -n "$call_dir" && "$(cat "$call_dir/degraded.txt" 2>/dev/null)" == "surface-context→detached" ]]; then
  pass "caller-resolution fallback names the degrade in degraded.txt"
else
  fail "caller-resolution fallback names the degrade in degraded.txt" \
       "got: $(cat "$call_dir/degraded.txt" 2>/dev/null || echo NONE)"
fi
if [[ -n "$call_dir" && "$(cat "$call_dir/placement.txt" 2>/dev/null)" == "detached" ]]; then
  pass "…and placement.txt reports the placement that HAPPENED, not the one asked for"
else
  fail "…and placement.txt reports the placement that HAPPENED, not the one asked for" \
       "got: $(cat "$call_dir/placement.txt" 2>/dev/null || echo NONE)"
fi
# The degraded callee still gets a reusable handle: it is in a tab of its own, and
# a follow-up that cannot find it opens yet another one.
if [[ -n "$call_dir" && "$(cat "$call_dir/surface_ref.txt" 2>/dev/null)" == "SURFACE-UUID-456" ]]; then
  pass "…and the degraded callee's surface is recorded by UUID for a follow-up to reuse"
else
  fail "…and the degraded callee's surface is recorded by UUID for a follow-up to reuse" \
       "got: $(cat "$call_dir/surface_ref.txt" 2>/dev/null || echo NONE)"
fi
if grep -q "send --workspace workspace:456 bash /tmp/hotline-launch" "$tmp/send_calls" 2>/dev/null; then
  pass "caller-resolution fallback sends launch script to the detached workspace"
else
  fail "caller-resolution fallback sends launch script to the detached workspace" \
       "send_calls=$(cat "$tmp/send_calls" 2>/dev/null)"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
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
# This one needs a stubbed PATH and a scratch --cwd: unlike the case above it
# does NOT exit at the guard, so with the real PATH it continued into cmux and
# launched an actual `claude --resume abc123` pane. That leak is what the
# poison stubs at the top of this file now catch.
fork_ok_tmp="$(mktemp -d)"
mkdir -p "$fork_ok_tmp/bin" "$fork_ok_tmp/cwd"
cat > "$fork_ok_tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
S="$0.screen"
case "$1" in
  new-workspace) echo "OK workspace:123" ;;
  # Round-trips surface-ready.sh's probe marker (typed line + output line) so the
  # detached readiness step succeeds instead of waiting out its budget.
  read-screen)   cat "$S" 2>/dev/null; echo "$ " ;;
  send)
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$S"; fi
    exit 0 ;;
  *)             exit 0 ;;
esac
EOF
chmod +x "$fork_ok_tmp/bin/cmux"
fork_ok_out=$(PATH="$fork_ok_tmp/bin:$PATH" bash "$SCRIPT_UNDER_TEST" \
  --cwd "$fork_ok_tmp/cwd" --prompt "hello" --fork-session --resume abc123 2>&1)
if printf '%s' "$fork_ok_out" | grep -q "fork-session requires --resume"; then
  fail "--fork-session with --resume passes the guard" "unexpected fork error: $fork_ok_out"
else
  pass "--fork-session with --resume passes the guard"
fi
rm -rf "$fork_ok_tmp"

# ---------------------------------------------------------------------------
# Fork placement: a FORK writes to a NEW session id, so the resume target is
# NOT where the transcript lands. cmux mode has no structured output to read
# the real id back from (unlike headless, which parses stream-json), so the
# launcher must CHOOSE the fork's id up front via --session-id and record that
# as the preset. Verified against the live CLI:
#   claude --resume A --fork-session --session-id B   → transcript lands in B
#   claude --resume A --session-id B                  → hard error:
#     "--session-id can only be used with --continue or --resume if
#      --fork-session is also specified."
# So --session-id is REQUIRED on a fork and FORBIDDEN on a plain resume.
# Regression: preset used to be the resume target on forks, so
# wait-for-session.sh returned the wrong id and wait-for-response.sh polled the
# original session's transcript — reporting "the message never submitted" while
# the fork had already answered.
# ---------------------------------------------------------------------------

# Minimal cmux fake whose new-workspace SUCCEEDS, so the launcher runs to
# completion and leaves the generated launch script in place to inspect.
make_ok_cmux() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
S="$0.screen"
case "$1" in
  new-workspace) echo "OK workspace:123" ;;
  # See above: the probe marker is echoed back so readiness succeeds.
  read-screen)   cat "$S" 2>/dev/null; echo "$ " ;;
  send)
    m=$(printf '%s' "$*" | grep -oE '__HOTLINE_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" ]]; then { echo "$m"; echo "$m"; } >> "$S"; fi
    exit 0 ;;
  *)             exit 0 ;;
esac
EOF
  chmod +x "$1"
}

run_detached_launch() {
  # Echoes "<call_dir>" after running the launcher with a succeeding cmux stub.
  local tmp="$1"; shift
  mkdir -p "$tmp/bin" "$tmp/cwd"
  make_ok_cmux "$tmp/bin/cmux"
  PATH="$tmp/bin:$PATH" bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" \
    --prompt "hello" "$@" > "$tmp/out.json" 2>"$tmp/err.txt"
  jq -r '.call_dir // empty' < "$tmp/out.json"
}

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
RESUME_TARGET="11111111-2222-3333-4444-555555555555"

# --- Fork: fresh preset + --session-id in the launch script -----------------
tmp=$(mktemp -d "$TMP_ROOT"/hotline-fork-test-XXXXXX)
call_dir=$(run_detached_launch "$tmp" --resume "$RESUME_TARGET" --fork-session)
if [[ -n "$call_dir" && -d "$call_dir" ]]; then
  preset=$(cat "$call_dir/session_id_preset.txt" 2>/dev/null || echo "")
  launch=$(cat "$(cat "$call_dir/launch_script.txt" 2>/dev/null)" 2>/dev/null || echo "")

  if [[ "$preset" != "$RESUME_TARGET" ]]; then
    pass "fork: session_id_preset is NOT the resume target"
  else
    fail "fork: session_id_preset is NOT the resume target" "preset=$preset"
  fi

  if [[ "$preset" =~ $UUID_RE ]]; then
    pass "fork: session_id_preset is a fresh lowercase UUID"
  else
    fail "fork: session_id_preset is a fresh lowercase UUID" "preset=$preset"
  fi

  if printf '%s' "$launch" | grep -q -- "--session-id"; then
    pass "fork: launch script passes --session-id"
  else
    fail "fork: launch script passes --session-id" "launch=$launch"
  fi

  if printf '%s' "$launch" | grep -q -- "--session-id $preset"; then
    pass "fork: --session-id matches the recorded preset"
  else
    fail "fork: --session-id matches the recorded preset" "preset=$preset launch=$launch"
  fi

  if printf '%s' "$launch" | grep -q -- "--resume $RESUME_TARGET" \
     && printf '%s' "$launch" | grep -q -- "--fork-session"; then
    pass "fork: launch script keeps --resume and --fork-session"
  else
    fail "fork: launch script keeps --resume and --fork-session" "launch=$launch"
  fi
else
  fail "fork: launcher returned a usable call_dir" "out=$(cat "$tmp/out.json" 2>/dev/null)"
fi
[[ -n "$call_dir" && -f "$call_dir/launch_script.txt" ]] && \
  rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# --- Plain resume: preset IS the resume target, NO --session-id -------------
tmp=$(mktemp -d "$TMP_ROOT"/hotline-fork-test-XXXXXX)
call_dir=$(run_detached_launch "$tmp" --resume "$RESUME_TARGET")
if [[ -n "$call_dir" && -d "$call_dir" ]]; then
  preset=$(cat "$call_dir/session_id_preset.txt" 2>/dev/null || echo "")
  launch=$(cat "$(cat "$call_dir/launch_script.txt" 2>/dev/null)" 2>/dev/null || echo "")

  if [[ "$preset" == "$RESUME_TARGET" ]]; then
    pass "plain resume: session_id_preset IS the resume target"
  else
    fail "plain resume: session_id_preset IS the resume target" "preset=$preset"
  fi

  # claude hard-errors on --resume + --session-id without --fork-session.
  if printf '%s' "$launch" | grep -q -- "--session-id"; then
    fail "plain resume: launch script omits --session-id" "launch=$launch"
  else
    pass "plain resume: launch script omits --session-id"
  fi
else
  fail "plain resume: launcher returned a usable call_dir" "out=$(cat "$tmp/out.json" 2>/dev/null)"
fi
[[ -n "$call_dir" && -f "$call_dir/launch_script.txt" ]] && \
  rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# --- HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE threads into the launch ---------
# The callee system-prompt override is baked into the launch script from the
# caller's env, as a FILE path (never the raw string, which would put a
# multi-line prompt on an argv `ps` can read), and only when the var is set.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-sysprompt-test-XXXXXX)
printf 'be terse.' > "$tmp/sysprompt.txt"

export HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$tmp/sysprompt.txt"
call_dir=$(run_detached_launch "$tmp")
unset HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE
if [[ -n "$call_dir" && -d "$call_dir" ]]; then
  launch=$(cat "$(cat "$call_dir/launch_script.txt" 2>/dev/null)" 2>/dev/null || echo "")
  if printf '%s' "$launch" | grep -q -- "--append-system-prompt-file $tmp/sysprompt.txt"; then
    pass "sysprompt: launch bakes --append-system-prompt-file with the caller's path"
  else
    fail "sysprompt: launch bakes --append-system-prompt-file with the caller's path" "launch=$launch"
  fi
  [[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
else
  fail "sysprompt: launcher returned a usable call_dir" "out=$(cat "$tmp/out.json" 2>/dev/null)"
fi
rm -rf "$tmp" "$call_dir"

# Absent when the var is unset — no stray flag on the default path.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-sysprompt-test-XXXXXX)
call_dir=$(run_detached_launch "$tmp")
if [[ -n "$call_dir" && -d "$call_dir" ]]; then
  launch=$(cat "$(cat "$call_dir/launch_script.txt" 2>/dev/null)" 2>/dev/null || echo "")
  if printf '%s' "$launch" | grep -q -- "--append-system-prompt-file"; then
    fail "sysprompt: no --append-system-prompt-file when the var is unset" "launch=$launch"
  else
    pass "sysprompt: no --append-system-prompt-file when the var is unset"
  fi
  [[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
else
  fail "sysprompt: launcher returned a usable call_dir (unset case)" "out=$(cat "$tmp/out.json" 2>/dev/null)"
fi
rm -rf "$tmp" "$call_dir"

# ---------------------------------------------------------------------------
# Stale launch-script sweep (claude-plugins-qq9f). Every dial reaps abandoned
# launch scripts older than 7 days before minting its own. Pointed at a scratch
# directory via HOTLINE_LAUNCH_SWEEP_DIR so the suite never touches the real /tmp.
# ---------------------------------------------------------------------------
echo ""
echo "Stale launch-script sweep:"

tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd" "$tmp/sweep"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
make_side_stub "$tmp/open-side.sh"

# BSD `touch -v-10d` vs GNU `date -d` — the suite runs on both macOS and CI Linux.
stale_ts=$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)
for f in hotline-launch-STALE hotline-cmux-launch-STALE; do
  echo 'exec claude' > "$tmp/sweep/$f"
  touch -t "$stale_ts" "$tmp/sweep/$f"
done
# Must survive: too young, and a name that isn't ours.
echo 'exec claude' > "$tmp/sweep/hotline-launch-FRESH"
echo 'not ours'    > "$tmp/sweep/someone-elses-file"
touch -t "$stale_ts" "$tmp/sweep/someone-elses-file"
mkdir -p "$tmp/sweep/hotline-launch-DIR"   # -type f only; a call dir is not a script

out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_LAUNCH_SWEEP_DIR="$tmp/sweep" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "sweep me" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')

if [[ ! -e "$tmp/sweep/hotline-launch-STALE" && ! -e "$tmp/sweep/hotline-cmux-launch-STALE" ]]; then
  pass "sweep deletes stale launch scripts under BOTH launcher prefixes"
else
  fail "sweep deletes stale launch scripts under BOTH launcher prefixes" \
       "remaining: $(ls "$tmp/sweep")"
fi
if [[ -f "$tmp/sweep/hotline-launch-FRESH" ]]; then
  pass "sweep leaves a launch script younger than the age floor alone"
else
  fail "sweep leaves a launch script younger than the age floor alone"
fi
if [[ -f "$tmp/sweep/someone-elses-file" && -d "$tmp/sweep/hotline-launch-DIR" ]]; then
  pass "sweep touches neither foreign filenames nor directories"
else
  fail "sweep touches neither foreign filenames nor directories" \
       "remaining: $(ls "$tmp/sweep")"
fi
if [[ -n "$call_dir" && -f "$call_dir/launch_script.txt" ]]; then
  pass "sweep does not disturb the launch script this dial just minted"
else
  fail "sweep does not disturb the launch script this dial just minted" \
       "call_dir=$call_dir stderr=$(cat "$tmp/stderr.txt")"
fi
[[ -n "$call_dir" && -f "$call_dir/launch_script.txt" ]] && \
  rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# ---------------------------------------------------------------------------
# --label: it reaches the tab through claude's OWN terminal title, and NOTHING
# here pins a static one.
#
# claude publishes its `-n` session name as the terminal title; cmux renders that
# live in the tab strip behind an activity glyph. `cmux rename-tab` would pin a
# static title that outranks it for the life of the tab, costing the glyph — so the
# side and window placements pass no title at all, and only a DETACHED callee, which
# has a workspace instead of a tab of its own, takes the label as a name.
# ---------------------------------------------------------------------------

# Opener stub that ECHOES --title back the way the real one does. Hotline passes
# none; the stub has to be able to report one for that absence to mean something.
make_titled_side_stub() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface invoked: $*" >> "${SIDE_STUB_LOG:?}"
TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in --title) TITLE="${2:-}"; shift 2 ;; *) shift ;; esac
done
jq -nc --arg t "$TITLE" --arg st "${SIDE_STUB_TITLE_STATUS:-}" \
  '{surface_ref:"surface:777", surface_id:"SURFACE-UUID-777",
    pane_ref:"pane:55", pane_id:"PANE-UUID-55", workspace_ref:"workspace:5",
    mode:"new-surface", ready:"ready",
    surface_title: (if $t == "" then null else $t end),
    title_status: (if $st != "" then $st elif $t == "" then "unset" else "applied" end)}'
EOF
  chmod +x "$1"
}

tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
make_titled_side_stub "$tmp/open-side.sh"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side.sh" SIDE_STUB_LOG="$tmp/side_log" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" \
    --name "hotline: fix 500s (work_order)" --label "fix 500s" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')

# CONTRACT GUARD. This absence IS the feature: a passing assertion here means no
# static title was pinned, and it fails the moment a --title passthrough returns.
if grep -q -- '--title' "$tmp/side_log" 2>/dev/null; then
  fail "the side opener is given NO --title, so claude's live title stands" \
       "side_log=$(cat "$tmp/side_log" 2>/dev/null)"
else
  pass "the side opener is given NO --title, so claude's live title stands"
fi
# CONTRACT GUARD, same reason: no rename anywhere on the side path.
if grep -qE 'rename-tab|tab-action' "$tmp/cmux_calls" 2>/dev/null; then
  fail "…and no cmux rename-tab is issued either" \
       "cmux calls: $(cat "$tmp/cmux_calls" 2>/dev/null)"
else
  pass "…and no cmux rename-tab is issued either"
fi
if [[ ! -e "$call_dir/label_status.txt" ]]; then
  pass "…so there is no title outcome to report, and none is written"
else
  fail "…so there is no title outcome to report, and none is written" \
       "got: $(cat "$call_dir/label_status.txt" 2>/dev/null)"
fi

# The `-n %q` reconstruction. The whole name has to arrive as ONE argv word however
# many spaces and parens are in it, so the expectation is DERIVED with the same %q
# the launcher uses rather than hand-quoted — a hand-quoted literal would drift the
# moment the name's shape did. Asserted on the argv word alone, not the whole
# script: the script also carries a `cd` line and whatever the ambient env adds.
launch=$(cat "$(cat "$call_dir/launch_script.txt")" 2>/dev/null)
labelled_name="hotline: fix 500s (work_order)"
if grep -qF -- "-n $(printf '%q' "$labelled_name") " <<<"$launch"; then
  pass "the labelled session name survives %q quoting as one argv word"
else
  fail "the labelled session name survives %q quoting as one argv word" "got=$launch"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# --- A ref-only opener payload DEGRADES visibly; no handle at all fails ------
# The guard exists for "nothing to address the callee by", and it used to test
# SURF_REF while the code below prefers SURF_ID — so the field that matters went
# unchecked and the field that renumbers was the one enforced.
#
# It does NOT hard-require the UUID. cmux-cli and hotline are separate plugins on
# independent versions, and a cmux-cli released before the UUID became mandatory
# returns refs with null ids; failing here would break a hotline upgrade on an
# un-upgraded sibling, which nothing declares a floor for. Reachable in practice:
# the cached openers under the plugins dir on this machine all predate the
# refusal. So the ref is accepted and the degrade is recorded where a failed dial
# is diagnosed.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
cat > "$tmp/open-side-refonly.sh" <<'EOF'
#!/usr/bin/env bash
# The pre-refusal opener's payload shape, verbatim: refs present, ids null.
jq -nc '{surface_ref:"surface:777", surface_id:null,
         pane_ref:"pane:55", pane_id:null, workspace_ref:"workspace:5",
         workspace_id:null, workspace_name:null,
         mode:"new-surface", ready:"ready", title_status:"applied"}'
EOF
chmod +x "$tmp/open-side-refonly.sh"
REFONLY_OUT=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side-refonly.sh" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" \
    --name "hotline: refonly (work_order)" --label "refonly" 2>"$tmp/stderr.txt")
refonly_cd=$(printf '%s' "$REFONLY_OUT" | jq -r '.call_dir // empty')
if [[ -n "$refonly_cd" && ! -f "$refonly_cd/error.txt" ]]; then
  pass "a ref-only opener payload still launches (no cmux-cli version floor to break on)"
else
  fail "a ref-only opener payload still launches (no cmux-cli version floor to break on)" \
       "out=$REFONLY_OUT err=$(cat "$refonly_cd/error.txt" 2>/dev/null)"
fi
# The degrade has to be VISIBLE, in the file a failed dial is read from — a send
# that lands on the wrong pane is otherwise indistinguishable from a transport bug.
if grep -qF "DEGRADED HANDLE" "$refonly_cd/surface_err.txt" 2>/dev/null; then
  pass "…and records the positional-ref degrade in surface_err.txt"
else
  fail "…and records the positional-ref degrade in surface_err.txt" \
       "surface_err=$(cat "$refonly_cd/surface_err.txt" 2>/dev/null)"
fi
# Naming the opener is what makes "update cmux-cli" actionable: the resolver picks
# from several roots and nothing else reports which one answered.
if grep -qF "open-side-refonly.sh" "$refonly_cd/surface_err.txt" 2>/dev/null; then
  pass "…naming the opener that answered"
else
  fail "…naming the opener that answered" "surface_err=$(cat "$refonly_cd/surface_err.txt" 2>/dev/null)"
fi
# And the callee is still addressed by the ref, since that is all there was.
if [[ "$(cat "$refonly_cd/surface_ref.txt" 2>/dev/null)" == "surface:777" ]]; then
  pass "…and falls back to the ref as the handle"
else
  fail "…and falls back to the ref as the handle" \
       "surface_ref.txt=$(cat "$refonly_cd/surface_ref.txt" 2>/dev/null)"
fi
[[ -n "$refonly_cd" && -f "$refonly_cd/launch_script.txt" ]] && rm -f "$(cat "$refonly_cd/launch_script.txt")"
rm -rf "$tmp" "$refonly_cd"

# --- NEITHER a UUID nor a ref: that is the real "nothing to send to" ---------
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
: > "$tmp/screen.txt"
make_min_surface_cmux "$tmp/bin"
cat > "$tmp/open-side-nothing.sh" <<'EOF'
#!/usr/bin/env bash
jq -nc '{surface_ref:null, surface_id:null, mode:"new-surface", ready:"ready"}'
EOF
chmod +x "$tmp/open-side-nothing.sh"
NOHANDLE_OUT=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  HOTLINE_OPEN_SIDE_SURFACE="$tmp/open-side-nothing.sh" \
  bash "$SCRIPT_UNDER_TEST" --cwd "$tmp/cwd" --prompt "hello" \
    --name "hotline: nohandle (work_order)" --label "nohandle" 2>"$tmp/stderr.txt")
nohandle_cd=$(printf '%s' "$NOHANDLE_OUT" | jq -r '.call_dir // empty')
if [[ "$(jq -r '.error // empty' "$nohandle_cd/error.txt" 2>/dev/null)" == *"neither a surface_id nor a surface_ref"* ]]; then
  pass "no handle at all fails the dial, which is what this guard is for"
else
  fail "no handle at all fails the dial, which is what this guard is for" \
       "out=$NOHANDLE_OUT error=$(cat "$nohandle_cd/error.txt" 2>/dev/null)"
fi
rm -rf "$tmp" "$nohandle_cd"

# --detached: the label names the WORKSPACE, prefixed. `--window <name>` resolves a
# window by the title of a workspace inside it, so a bare subject as a workspace
# title could be picked up as a later dial's --window target.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
echo "$*" >> "$ST/cmux_calls"
case "$1" in
  new-workspace) echo "OK workspace:123" ;;
  read-screen)   cat "$ST/screen.txt" 2>/dev/null ;;
  send)          shift; printf '%s\n%s\n' "$*" "$*" >> "$ST/screen.txt" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/cmux"
: > "$tmp/screen.txt"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" HOTLINE_SURFACE_READY_TIMEOUT=2 \
  bash "$SCRIPT_UNDER_TEST" --detached --cwd "$tmp/cwd" --prompt "hello" \
    --name "hotline: fix 500s (work_order)" --label "fix 500s" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if grep -qF -- 'new-workspace --cwd '"$tmp/cwd"' --name hotline: fix 500s' "$tmp/cmux_calls" 2>/dev/null; then
  pass "--detached names the workspace from the label, prefixed hotline:"
else
  fail "--detached names the workspace from the label, prefixed hotline:" \
       "cmux calls: $(cat "$tmp/cmux_calls" 2>/dev/null)"
fi
# The MODE is deliberately absent from the workspace name: `--window <name>`
# resolves by workspace title, so the name a later dial might be asked to find has
# to be the one a caller would type — the label, not the label plus punctuation.
if grep -qF -- '--name hotline: fix 500s (work_order)' "$tmp/cmux_calls" 2>/dev/null; then
  fail "…without the mode suffix the session name carries" \
       "cmux calls: $(cat "$tmp/cmux_calls" 2>/dev/null)"
else
  pass "…without the mode suffix the session name carries"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# --window: NOTHING is renamed, and the cached surface handle is the UUID the
# opener now reports rather than the positional ref it used to be the only source
# of. A positional `surface:N` names whatever sits in slot N right now, and slot N
# in the caller's own workspace is a different surface from slot N in the callee's
# window (claude-plugins-h2et).
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
echo "$*" >> "$ST/cmux_calls"
case "$1" in
  # The tree is read TWICE on this path: once to resolve the window, and once
  # after new-surface to map the new ref to its UUID. surface:200 has to be in it
  # for the second lookup to find anything — a fixture that omitted it would let
  # the positional fallback pass for the wrong reason.
  tree)        echo '{"windows":[{"id":"WIN-B","ref":"window:2","workspaces":[{"id":"WS-P","ref":"workspace:5","title":"proj","panes":[{"ref":"pane:1","index":0,"surfaces":[{"ref":"surface:200","id":"11111111-2222-4333-8444-555555555555","pane_id":"PANE-UUID-9","title":"zsh"}]}]}]}]}' ;;
  new-surface) echo "OK surface:200 pane:9 workspace:5" ;;
  # The readiness probe wants to see `echo MARKER` TWICE — the typed line plus the
  # output of a shell that actually ran it. Echoing each send twice is that shape.
  send)        shift; printf '%s\n%s\n' "$*" "$*" >> "$ST/screen.txt" ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  rename-tab)  echo "OK" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/cmux"
: > "$tmp/screen.txt"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" HOTLINE_SURFACE_READY_TIMEOUT=4 \
  bash "$SCRIPT_UNDER_TEST" --window "window:2" --cwd "$tmp/cwd" --prompt "hello" \
    --name "hotline: fix 500s (work_order)" --label "fix 500s" 2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if [[ -n "$call_dir" && ! -f "$call_dir/error.txt" ]]; then
  pass "--window with a label launches cleanly"
else
  fail "--window with a label launches cleanly" \
       "out=$out error=$(cat "$call_dir/error.txt" 2>/dev/null) stderr=$(cat "$tmp/stderr.txt")"
fi
if [[ "$(cat "$call_dir/surface_ref.txt" 2>/dev/null)" == "11111111-2222-4333-8444-555555555555" ]]; then
  pass "the cached --window handle is the surface's UUID, not its positional ref"
else
  fail "the cached --window handle is the surface's UUID, not its positional ref" \
       "got: $(cat "$call_dir/surface_ref.txt" 2>/dev/null)"
fi
if grep -qF -- 'send --surface 11111111-2222-4333-8444-555555555555' "$tmp/cmux_calls" 2>/dev/null; then
  pass "…and the launch send is addressed by that UUID too"
else
  fail "…and the launch send is addressed by that UUID too" \
       "cmux calls: $(cat "$tmp/cmux_calls" 2>/dev/null)"
fi
# CONTRACT GUARD: this was the one placement that renamed a surface after the fact.
if grep -qE 'rename-tab|rename-workspace|tab-action' "$tmp/cmux_calls" 2>/dev/null; then
  fail "…with nothing renamed: not the surface, not the workspace title" \
       "cmux calls: $(cat "$tmp/cmux_calls" 2>/dev/null)"
else
  pass "…with nothing renamed: not the surface, not the workspace title"
fi
# CONTRACT GUARD: the workspace title is `--window <name>`'s addressing key, so a
# label must never become one — a dial that created `fix 500s` as a workspace title
# could be adopted as a later `--window fix 500s` target.
if grep -qE 'new-workspace .*--name (hotline: )?fix' "$tmp/cmux_calls" 2>/dev/null; then
  fail "…and no workspace is created carrying the label" \
       "cmux calls: $(cat "$tmp/cmux_calls" 2>/dev/null)"
else
  pass "…and no workspace is created carrying the label"
fi
[[ -f "$call_dir/launch_script.txt" ]] && rm -f "$(cat "$call_dir/launch_script.txt")"
rm -rf "$tmp" "$call_dir"

# --window, PTY NEVER READY: the surface we just opened is reaped, scoped to its
# workspace. THE CONTAINER IS NOT OPTIONAL — `cmux close-surface --surface <uuid>`
# resolves inside the caller's inherited workspace context and answers "Surface not
# found" out of it, so the close that passed --surface alone silently no-op'd and
# left a wedged surface in the user's window (claude-plugins-5k43). This is the
# least-travelled of the three close sites, which is exactly why it needs its own
# bite: reverting it to a bare `|| true` used to leave every suite green.
make_unready_window_cmux() {  # $1 = bin dir
  mkdir -p "$1"
  cat > "$1/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
echo "$*" >> "$ST/cmux_calls"
case "$1" in
  tree)        echo '{"windows":[{"id":"WIN-B","ref":"window:2","workspaces":[{"id":"WS-P","ref":"workspace:5","title":"proj","panes":[{"ref":"pane:1","index":0,"surfaces":[{"ref":"surface:200","id":"11111111-2222-4333-8444-555555555555","pane_id":"PANE-UUID-9","title":"zsh"}]}]}]}]}' ;;
  new-surface) echo "OK surface:200 pane:9 workspace:5" ;;
  # The readiness probe wants the marker back TWICE. This shell swallows input, so
  # it never echoes at all — the PTY-never-attached case.
  send)        exit 0 ;;
  read-screen) exit 0 ;;
  close-surface)
    echo "$*" >> "$ST/close_calls"
    if [[ -n "${CMUX_REFUSE_CLOSE:-}" ]]; then
      echo 'not_found: Surface not found' >&2
      exit 1
    fi ;;
esac
exit 0
EOF
  chmod +x "$1/cmux"
}

tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
make_unready_window_cmux "$tmp/bin"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" HOTLINE_SURFACE_READY_TIMEOUT=1 \
  bash "$SCRIPT_UNDER_TEST" --window "window:2" --cwd "$tmp/cwd" --prompt "hello" \
  2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if [[ -n "$call_dir" && -f "$call_dir/done" && -f "$call_dir/error.txt" ]]; then
  pass "--window readiness timeout writes the async error contract"
else
  fail "--window readiness timeout writes the async error contract" \
       "call_dir=$call_dir out=$out stderr=$(cat "$tmp/stderr.txt")"
fi
if grep -q "close-surface --workspace WS-P --surface 11111111-2222-4333-8444-555555555555" \
     "$tmp/close_calls" 2>/dev/null; then
  pass "…and reaps the unready surface with --workspace, both halves as UUIDs"
else
  fail "…and reaps the unready surface with --workspace, both halves as UUIDs" \
       "close_calls=$(cat "$tmp/close_calls" 2>/dev/null || echo NONE)"
fi
if ! grep -qE 'close-surface --surface' "$tmp/close_calls" 2>/dev/null; then
  pass "…and never the unscoped form, which resolves out of the caller's own workspace"
else
  fail "…and never the unscoped form, which resolves out of the caller's own workspace" \
       "close_calls=$(cat "$tmp/close_calls" 2>/dev/null)"
fi
rm -rf "$tmp" "$call_dir"

# …and a close cmux REFUSES is recorded, not swallowed: the call is failing anyway,
# so the only thing that says a wedged surface was left behind is this diagnostic.
tmp=$(mktemp -d "$TMP_ROOT"/hotline-cmux-test-XXXXXX)
mkdir -p "$tmp/cwd"
make_unready_window_cmux "$tmp/bin"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" CMUX_REFUSE_CLOSE=1 \
  HOTLINE_SURFACE_READY_TIMEOUT=1 \
  bash "$SCRIPT_UNDER_TEST" --window "window:2" --cwd "$tmp/cwd" --prompt "hello" \
  2>"$tmp/stderr.txt")
call_dir=$(printf '%s' "$out" | jq -r '.call_dir // empty')
if grep -q "failed to close the unready surface 11111111-2222-4333-8444-555555555555" \
     "$call_dir/surface_err.txt" 2>/dev/null; then
  pass "a refused --window reap lands in surface_err.txt, not in \`|| true\`"
else
  fail "a refused --window reap lands in surface_err.txt, not in \`|| true\`" \
       "surface_err=$(cat "$call_dir/surface_err.txt" 2>/dev/null || echo NONE)"
fi
rm -rf "$tmp" "$call_dir"

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
