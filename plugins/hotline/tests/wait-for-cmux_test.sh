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

# Case 3b: no banner, but the transcript file APPEARS during the wait (Signal B) →
# session_id.txt promoted from preset. Verifies the second REPL-boot signal
# independently.
#
# It has to appear mid-wait rather than be staged beforehand: signal B requires the
# file to have GROWN since the wait started. A file that was already sitting there
# is every plain resume, where the transcript predates the dial — and a bare
# existence check fired on the first poll, reporting a booted REPL in the same
# millisecond the launch command was sent (Case 3b2 below pins that).
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
( sleep 1; echo '{"type":"user"}' > "$tmp/home/.claude/projects/$ENC/preset-uuid-3b.jsonl" ) &
WRITER=$!

out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 8 2>"$tmp/err.txt")
rc=$?
wait $WRITER 2>/dev/null || true
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

# Case 3b2: a transcript that was ALREADY there and never changes — the shape of
# every plain resume. It must NOT count as a booted REPL.
tmp=$(mktemp -d /tmp/hotline-wait-test-XXXXXX)
make_fake_cmux "$tmp/bin"
cat > "$tmp/screen.txt" <<'EOF'
Last login: Thu May 14 16:00:00 on ttys001
 some shell prompt with no banner yet
EOF
cd="$tmp/call"
stage_call_dir "$cd" "preset-uuid-3b2" "workspace:98"
RECV_CWD="/Users/fake/Code/proj.name"
echo "$RECV_CWD" > "$cd/cwd.txt"
ENC=$(printf '%s' "$RECV_CWD" | sed 's|[/.]|-|g')
mkdir -p "$tmp/home/.claude/projects/$ENC"
printf '{"type":"user","message":{"content":"a turn from last week"}}\n' \
  > "$tmp/home/.claude/projects/$ENC/preset-uuid-3b2.jsonl"

out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CMUX_FAKE_SCREEN="$tmp/screen.txt" \
  bash "$WAIT_SESSION" "$cd" --timeout 3 2>"$tmp/err.txt")
rc=$?
if [[ $rc -ne 0 && ! -f "$cd/session_id.txt" ]]; then
  pass "a pre-existing, unchanged transcript is NOT a boot signal (resume)"
else
  fail "a pre-existing, unchanged transcript is NOT a boot signal (resume)" \
       "rc=$rc stdout=$out"
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
echo "wait-for-session launch-line fast-fail:"

# A fake cmux that serves a SEQUENCE of screens, one per read-screen, and logs
# everything. The launch-error retry cannot be tested against a static screen: the
# whole question is what the NEXT poll sees after the re-send went out.
make_seq_cmux() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/cmux" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "${CMUX_SEQ_LOG:?CMUX_SEQ_LOG not set}"; printf '\n' >> "$CMUX_SEQ_LOG"
case "$1" in
  read-screen)
    d="${CMUX_SEQ_DIR:?CMUX_SEQ_DIR not set}"
    n=$(cat "$d/count"); c=$(cat "$d/cursor")
    c=$((c + 1)); [[ $c -gt $n ]] && c=$n
    echo "$c" > "$d/cursor"
    cat "$d/$c.txt"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bin_dir/cmux"
}

# The live claude input box pads its ❯ with U+00A0; a shell prompt pads with an
# ordinary space. Only the first is a REPL.
SEQ_GLYPH=$'\xe2\x9d\xaf'
SEQ_NBSP=$'\xc2\xa0'

# Stage screens/1.txt … screens/N.txt from the function names passed in.
stage_screens() {
  local d="$1"; shift
  mkdir -p "$d"
  local i=1 fn
  for fn in "$@"; do "$fn" > "$d/$i.txt"; i=$((i + 1)); done
  echo $((i - 1)) > "$d/count"
  echo 0 > "$d/cursor"
}

# The mangle: three of the user's keystrokes landed ahead of our launch command, so
# the shell refused the whole line. This is the screen the fast-fail exists for.
seq_screen_mangled() {
  printf 'Last login: Thu May 14 16:00:00 on ttys001\n~/Code/target\nzsh: command not found: rkebash\n~/Code/target\n'
}
# ONE SECOND AFTER THE RE-SEND, which is where this regressed. Ctrl-U clears the
# input LINE, not the screen, so the refusal we already retried on is still sitting
# there — and claude's banner needs 1-3s, so nothing has replaced it yet. Reading
# this as "the re-send was refused too" abandoned a surface where claude was booting.
seq_screen_mangled_resent() {
  printf 'Last login: Thu May 14 16:00:00 on ttys001\n~/Code/target\nzsh: command not found: rkebash\n~/Code/target bash /tmp/launch\n'
}
# The re-send worked: the REPL is up and its box is drawn. The old error line is
# still in the capture above it.
seq_screen_booted() {
  printf 'zsh: command not found: rkebash\n~/Code/target bash /tmp/launch\n\n%s\n%s%s\n%s\n  ? for shortcuts\n' \
    "$(printf '─%.0s' {1..20})" "$SEQ_GLYPH" "$SEQ_NBSP" "$(printf '─%.0s' {1..20})"
}
# The re-send was refused TOO: a second, distinct diagnostic joins the first.
seq_screen_mangled_twice() {
  printf 'zsh: command not found: rkebash\n~/Code/target\nzsh: command not found: qqbash\n~/Code/target\n'
}
# A HEALTHY REPL that shelled out and hit a missing file. Both halves of the old
# whole-line match are here — a not-found phrase, and the word bash — but `bash` is
# the shell's own name in front of somebody else's token, so this is not our launch
# line and must not fail the boot.
seq_screen_tool_result() {
  printf 'Last login: Thu May 14 16:00:00 on ttys001\n  Bash(cat /tmp/nope)\n  ⎿  bash: cat: /tmp/nope: No such file or directory\n  ⏺ That file is not there.\n'
}

run_seq_case() {  # <name> <preset> <timeout> <screen-fn>...
  local name="$1" preset="$2" timeout="$3"; shift 3
  SEQ_TMP=$(mktemp -d /tmp/hotline-wait-seq-XXXXXX)
  make_seq_cmux "$SEQ_TMP/bin"
  stage_screens "$SEQ_TMP/screens" "$@"
  SEQ_CD="$SEQ_TMP/call"
  stage_call_dir "$SEQ_CD" "$preset" "workspace:77"
  # A REAL launch script, because the one-shot retry only fires when the recorded
  # path still exists.
  SEQ_LAUNCH="$SEQ_TMP/hotline-launch-fake"
  echo 'exec claude' > "$SEQ_LAUNCH"
  echo "$SEQ_LAUNCH" > "$SEQ_CD/launch_script.txt"
  SEQ_OUT=$(PATH="$SEQ_TMP/bin:$PATH" CMUX_SEQ_DIR="$SEQ_TMP/screens" \
    CMUX_SEQ_LOG="$SEQ_TMP/calls.log" \
    bash "$WAIT_SESSION" "$SEQ_CD" --timeout "$timeout" 2>"$SEQ_TMP/err.txt")
  SEQ_RC=$?
  SEQ_ERR=$(cat "$SEQ_TMP/err.txt")
}

# Case 5: THE STALE ERROR LINE. Poll 1 sees the refusal and re-sends; poll 2 sees
# the SAME line still on screen; poll 3 sees the box. It must boot, not exit 1.
run_seq_case stale_err preset-uuid-5 8 \
  seq_screen_mangled seq_screen_mangled_resent seq_screen_booted
if [[ $SEQ_RC -eq 0 && "$SEQ_OUT" == "preset-uuid-5" ]]; then
  pass "a stale error line after the re-send does not abandon a booting REPL"
else
  fail "a stale error line after the re-send does not abandon a booting REPL" \
       "rc=$SEQ_RC stdout=$SEQ_OUT stderr=$SEQ_ERR"
fi
if [[ "$SEQ_ERR" == *"Clearing the input line and re-sending it once"* ]]; then
  pass "…and the one-shot re-send did fire"
else
  fail "…and the one-shot re-send did fire" "stderr=$SEQ_ERR"
fi
if [[ "$SEQ_ERR" != *"clean re-send did not help"* ]]; then
  pass "…without reporting the re-send as failed"
else
  fail "…without reporting the re-send as failed" "stderr=$SEQ_ERR"
fi
if grep -qE "^send --workspace workspace:77 .*bash" "$SEQ_TMP/calls.log"; then
  pass "…and the re-send named the workspace explicitly (never the focused surface)"
else
  fail "…and the re-send named the workspace explicitly (never the focused surface)" \
       "$(cat "$SEQ_TMP/calls.log")"
fi
rm -rf "$SEQ_TMP"

# Case 5b: a NEW refusal after the re-send is still fatal, and fast. The count of
# matching lines grows, which is what tells this apart from Case 5.
run_seq_case twice_err preset-uuid-5b 8 \
  seq_screen_mangled seq_screen_mangled_twice
if [[ $SEQ_RC -ne 0 && "$SEQ_ERR" == *"clean re-send did not help"* ]]; then
  pass "a second, distinct refusal after the re-send is reported as fatal"
else
  fail "a second, distinct refusal after the re-send is reported as fatal" \
       "rc=$SEQ_RC stderr=$SEQ_ERR"
fi
if [[ ! -f "$SEQ_CD/session_id.txt" ]]; then
  pass "…and session_id.txt is NOT promoted"
else
  fail "…and session_id.txt is NOT promoted"
fi
rm -rf "$SEQ_TMP"

# Case 5c: TOKEN SCOPING. A healthy REPL's tool result carries a not-found phrase
# and the word bash on one line. The old whole-line match called that a refused
# launch line and re-sent `bash /tmp/…` into a live claude REPL.
run_seq_case tool_result preset-uuid-5c 2 seq_screen_tool_result
if [[ "$SEQ_ERR" != *"refused the launch line"* ]]; then
  pass "a tool result naming bash and a missing file is not a refused launch line"
else
  fail "a tool result naming bash and a missing file is not a refused launch line" \
       "stderr=$SEQ_ERR"
fi
if ! grep -qE "^send " "$SEQ_TMP/calls.log"; then
  pass "…so no launch line is re-sent into it"
else
  fail "…so no launch line is re-sent into it" "$(cat "$SEQ_TMP/calls.log")"
fi
rm -rf "$SEQ_TMP"

# Case 5d: the refusal we retried on and never saw replaced is quoted by the
# timeout, so the one failure this fast-fail exists for never reads as a generic
# "REPL did not boot" again.
run_seq_case quoted_err preset-uuid-5d 3 \
  seq_screen_mangled seq_screen_mangled_resent seq_screen_mangled_resent
if [[ $SEQ_RC -ne 0 && "$SEQ_ERR" == *"Timed out waiting for Claude REPL to boot"* \
      && "$SEQ_ERR" == *"a re-send did not visibly boot: zsh: command not found: rkebash"* ]]; then
  pass "the timeout diagnostic quotes the refused launch line"
else
  fail "the timeout diagnostic quotes the refused launch line" "rc=$SEQ_RC stderr=$SEQ_ERR"
fi
rm -rf "$SEQ_TMP"

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
  read-screen)    echo "$@" >> "${CMUX_FAKE_STATE:?}/read_calls"; cat "${CMUX_FAKE_SCREEN:?}" ;;
  focus-pane)     echo "$@" >> "${CMUX_FAKE_STATE:?}/focus_calls" ;;
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
# The boot wait is handed a pane_ref and must NOT focus it. The launcher has already
# SENT to this target and the send is what attaches the PTY, so a focus call here
# attaches nothing and only moves the user's cursor into a booting callee
# (claude-plugins-r465.4).
if [[ ! -s "$tmp/focus_calls" ]]; then
  pass "surface mode: the boot wait never focuses the callee's pane"
else
  fail "surface mode: the boot wait never focuses the callee's pane" \
       "focus=$(cat "$tmp/focus_calls" 2>/dev/null)"
fi
# Scroll immunity: a bare read-screen returns the user's scrolled viewport, so a
# scrolled callee pane would look like a REPL that never booted for the whole
# 60s budget (claude-plugins-r465.5).
plain_reads=$(grep -vc -- '--scrollback' "$tmp/read_calls" 2>/dev/null || true)
if [[ -s "$tmp/read_calls" && "${plain_reads:-1}" -eq 0 ]]; then
  pass "surface mode: every boot-wait read carries --scrollback"
else
  fail "surface mode: every boot-wait read carries --scrollback" \
       "reads=$(cat "$tmp/read_calls" 2>/dev/null)"
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
