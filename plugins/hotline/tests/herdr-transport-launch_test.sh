#!/usr/bin/env bash
# =============================================================================
# herdr transport regression tests: preflight, the launcher's call-dir contract,
# placement, and the doc canaries that pin the launcher's stated defaults
# (sections 1, 2, 2b, 8).
#
# One shard of the herdr-transport suite. What the suite pins, the stubs and
# their knobs live in lib/herdr-transport-harness.sh; the sibling
# herdr-transport-*_test.sh shards hold the other sections.
# =============================================================================
set -u
# shellcheck source=lib/herdr-transport-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr-transport-harness.sh"

# ===========================================================================
echo "1. Preflight (check-herdr.sh) — three questions, three answers:"
# ===========================================================================

# The poison stub IS on PATH (that is its job), so `command -v herdr` would succeed.
# A PATH that omits BOTH the poison dir and herdr's real home models a machine with
# no herdr at all, while still carrying jq and the coreutils the script needs.
t=$(new_env)
NOHERDR_PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin"
out=$(env PATH="$NOHERDR_PATH" HOME="$t/home" bash "$CHECK_HERDR" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.usable' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"not on PATH"* ]]
check "no herdr binary → usable:false naming PATH (an install problem)" $? \
  "rc=$rc out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_SESSION_RC=1 \
      bash "$CHECK_HERDR" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no server answered"* ]]
check "herdr installed but no server → usable:false naming the server, not the binary" $? \
  "rc=$rc out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_NO_PANES=1 \
      bash "$CHECK_HERDR" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no pane could be resolved"* ]]
check "herdr up but no pane → usable:false BEFORE any call dir is minted" $? \
  "rc=$rc out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_PANE="w3:p7" \
      bash "$CHECK_HERDR" 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$(jq -r '.usable' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.pane' <<<"$out" 2>/dev/null)" == "w3:p7" ]]
check "server reachable + a pane → usable:true, reporting the pane it found" $? \
  "rc=$rc out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_ENV=1 HERDR_PANE_ID="w9:p1" \
      HERDR_STUB_SESSION_RC=1 bash "$CHECK_HERDR" 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$(jq -r '.pane' <<<"$out" 2>/dev/null)" == "w9:p1" ]]
check "HERDR_ENV=1 is proof of a server on its own, and \$HERDR_PANE_ID is the pane" $? \
  "rc=$rc out=$out"
[[ ! -s "$t/herdr.log" ]]
check "…and it costs no herdr call at all (the env already answered both)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# ===========================================================================
echo ""
echo "2. The launcher's call-dir contract:"
# ===========================================================================

t=$(new_env)
printf '/hotline:hotline-ringing [MODE: work_order] [CALLER: /caller/cwd] [SESSION: caller-9]\nrun the suite\n' \
  > "$t/prompt.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_NEW_PANE="w1:p4" HERDR_PANE_ID="w1:p1" \
      HOTLINE_HERDR_PANE_SETTLE=0 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt-file "$t/prompt.md" \
        --detached 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -d "$cd_path" ]]
check "returns a call_dir" $? "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(cat "$cd_path/transport.txt" 2>/dev/null)" == "herdr" ]]
check "transport.txt = herdr" $? "got '$(cat "$cd_path/transport.txt" 2>/dev/null)'"

agent=$(cat "$cd_path/herdr_agent.txt" 2>/dev/null || true)
[[ -n "$agent" && "$agent" =~ ^[a-z][a-z0-9_-]{0,31}$ && "$agent" == hotline-* ]]
check "herdr_agent.txt holds a herdr-legal name ([a-z][a-z0-9_-]{0,31}, hotline- prefixed)" $? \
  "got '$agent' (${#agent} chars)"

[[ "$(cat "$cd_path/herdr_pane.txt" 2>/dev/null)" == "w1:p4" ]]
check "herdr_pane.txt names the pane the SPLIT created, not the one it split from" $? \
  "got '$(cat "$cd_path/herdr_pane.txt" 2>/dev/null)'"

# The CANONICAL cwd, not the string we were handed: the transcript path is derived
# from this, and Claude Code encodes the path it resolved. (Under $TMPDIR on macOS
# these differ — /tmp is a symlink to /private/tmp — which is what makes this
# assertion meaningful rather than tautological.)
[[ "$(cat "$cd_path/cwd.txt" 2>/dev/null)" == "$(cd "$t/target" && pwd -P)" ]]
check "cwd.txt records the callee cwd, canonicalized (the transcript path derives from it)" $? \
  "got '$(cat "$cd_path/cwd.txt" 2>/dev/null)' want '$(cd "$t/target" && pwd -P)'"

preset=$(cat "$cd_path/session_id_preset.txt" 2>/dev/null || true)
[[ "$preset" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
check "session_id_preset.txt is a lowercase UUID" $? "got '$preset'"

[[ "$(cat "$cd_path/session_id.txt" 2>/dev/null)" == "$preset" ]]
check "session_id.txt is written BY THE LAUNCHER (agent start already blocked on boot)" $? \
  "got '$(cat "$cd_path/session_id.txt" 2>/dev/null)' vs preset '$preset'"

nonce=$(cat "$cd_path/call_id.txt" 2>/dev/null || true)
[[ -n "$nonce" ]] && grep -qF "[CALL_ID: $nonce]" "$cd_path/pending_paste.md"
check "pending_paste.md holds the nonce-injected prompt" $? \
  "nonce='$nonce' paste=$(head -c 120 "$cd_path/pending_paste.md" 2>/dev/null)"

# The nonce goes INLINE after the slash-command token, never on a line above it:
# a leading header line stops claude parsing the invocation as a command at all.
head -1 "$cd_path/pending_paste.md" | grep -q '^/hotline:hotline-ringing \[CALL_ID: '
check "…injected INLINE after the slash command (shared rule, via repl-state.sh)" $? \
  "first line: $(head -1 "$cd_path/pending_paste.md")"

# GNU `stat -c` FIRST, BSD `stat -f` as the fallback — never the other way round.
# On Linux `stat -f` is `--file-system`: it succeeds with verbose output instead of
# failing, so a BSD-first chain never reaches its fallback and this assertion reads
# garbage on the ubuntu runner.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1" 2>/dev/null; }
[[ "$(file_mode "$cd_path/pending_paste.md")" == "600" ]]
check "pending_paste.md is 0600 (a work order is not readable by other local users)" $? \
  "mode=$(file_mode "$cd_path/pending_paste.md")"

[[ "$(cat "$cd_path/keep_workspace.txt" 2>/dev/null)" == "true" ]]
check "keep_workspace.txt = true (a herdr agent outlives the call by design)" $? \
  "got '$(cat "$cd_path/keep_workspace.txt" 2>/dev/null)'"

[[ "$(cat "$cd_path/mode.txt" 2>/dev/null)" == "work_order" \
   && "$(cat "$cd_path/caller_session.txt" 2>/dev/null)" == "caller-9" ]]
check "persist-call-meta.sh ran, so register-call.sh has what it needs" $? \
  "mode='$(cat "$cd_path/mode.txt" 2>/dev/null)' caller='$(cat "$cd_path/caller_session.txt" 2>/dev/null)'"

[[ ! -f "$cd_path/surface_ref.txt" && ! -f "$cd_path/workspace_ref.txt" ]]
check "writes NO cmux handle (so a stale transport.txt could never be read as cmux)" $? \
  "call_dir: $(ls "$cd_path" | tr '\n' ' ')"

# --- what the launcher actually asked herdr to do ---------------------------
grep -q "pane split --pane w1:p1 --direction right --cwd $(cd "$t/target" && pwd -P) --no-focus" \
  <(tr -d '\\' < "$t/herdr.log")
check "splits the resolved pane with the callee's canonical cwd and --no-focus" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

grep -q -- "agent start $agent --kind claude --pane w1:p4" <(tr -d '\\' < "$t/herdr.log")
check "starts a claude agent in the NEW pane, by name" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

grep -q -- "-- --session-id $preset" <(tr -d '\\' < "$t/herdr.log")
check "presets the callee's session id through the -- passthrough" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The `=`-joined single-argv form, not `--allowedTools <list>`.
grep -q -- "--allowedTools=Bash" <(tr -d '\\' < "$t/herdr.log")
check "passes --allowedTools=<list> as ONE argv word" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

! grep -q -- "--dangerously-skip-permissions" "$t/herdr.log" 2>/dev/null
check "does NOT pass --dangerously-skip-permissions unless asked (a real trust decision)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

! grep -q "run the suite" "$t/herdr.log" 2>/dev/null
check "the work order never reaches the launch argv (claude-plugins-86ka)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- opt-in flags ----------------------------------------------------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1 HOTLINE_CLAUDE_MODEL=opus \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" --tools "Read Grep" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"--dangerously-skip-permissions"* && "$log" == *"--model opus"* \
   && "$log" == *"--allowedTools=Read Grep"* ]]
check "HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS / _CLAUDE_MODEL / --tools all reach claude" $? \
  "herdr calls: $log"

# --- the busy-pane race ----------------------------------------------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_BUSY_TIMES=2 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -s "$cd_path/herdr_agent.txt" && ! -f "$cd_path/error.txt" ]]
check "agent_pane_busy is retried (a freshly split pane needs a moment)" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null)"
[[ "$(grep -c 'agent start' "$t/herdr.log" 2>/dev/null)" -eq 3 ]]
check "…exactly as many times as it took, then stops" $? \
  "agent start calls: $(grep -c 'agent start' "$t/herdr.log" 2>/dev/null)"

# --- readiness, not a stopwatch --------------------------------------------
# The bug this replaces: the launcher slept a fixed second and then spent its four
# `agent start` attempts discovering the pane was not at its prompt yet. On a loaded
# box (two pipeline runs plus a test suite) that budget ran out and a real work-order
# dial died `agent_pane_busy`. `pane process-info` answers the question directly —
# the pane is available exactly when its foreground process group IS the shell — so
# the wait belongs in a poll on that, not in burned start attempts.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_PANE_BUSY_TIMES=3 \
      HOTLINE_HERDR_READY_POLL=0 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -s "$cd_path/herdr_agent.txt" && ! -f "$cd_path/error.txt" ]]
check "a pane not yet at its prompt is WAITED for, not retried into the ground" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null) stderr=$(cat "$t/err.txt")"
[[ "$(grep -c 'pane process-info' "$t/herdr.log" 2>/dev/null)" -ge 4 ]]
check "…by polling pane process-info until the shell is the foreground group" $? \
  "process-info calls: $(grep -c 'pane process-info' "$t/herdr.log" 2>/dev/null)"
[[ "$(grep -c 'agent start' "$t/herdr.log" 2>/dev/null)" -eq 1 ]]
check "…so the start itself costs ONE attempt, not one per second of shell boot" $? \
  "agent start calls: $(grep -c 'agent start' "$t/herdr.log" 2>/dev/null)"

# A start that races past the poll anyway is still retried — readiness is read at one
# instant and acted on at the next, so the backoff stays as the second guard.
t=$(new_env)
started=$(date +%s)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_BUSY_TIMES=3 \
      HOTLINE_HERDR_START_BUDGET=20 HOTLINE_HERDR_READY_POLL=0 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
elapsed=$(( $(date +%s) - started ))
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -s "$cd_path/herdr_agent.txt" && ! -f "$cd_path/error.txt" && $elapsed -lt 20 ]]
check "agent_pane_busy N times then success still lands, inside the budget" $? \
  "elapsed=${elapsed}s out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null)"

# --- the budget is the stop, and it still says what failed and where ---------
t=$(new_env)
started=$(date +%s)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_NEW_PANE="w1:p9" \
      HERDR_STUB_PANE_BUSY_TIMES=99999 HERDR_STUB_BUSY_TIMES=99999 \
      HOTLINE_HERDR_START_BUDGET=2 HOTLINE_HERDR_READY_POLL=0 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
elapsed=$(( $(date +%s) - started ))
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -f "$cd_path/error.txt" ]] \
  && grep -qE 'failed in pane w1:p9 after [0-9]+ attempt\(s\)' "$cd_path/error.txt" \
  && grep -q 'agent_pane_busy' "$cd_path/error.txt"
check "an exhausted budget still names the pane, the attempt count and the cause" $? \
  "error=$(cat "$cd_path/error.txt" 2>/dev/null)"
[[ $elapsed -lt 25 ]]
check "…and stops at the budget instead of spending every attempt's full wait" $? \
  "elapsed=${elapsed}s"

# A herdr that cannot answer the readiness question must not become a hang: the poll
# gives up on an unreadable pane and the bounded backoff carries the call, exactly as
# it did before process-info existed.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_PROCINFO_FAIL=1 \
      HERDR_STUB_BUSY_TIMES=1 HOTLINE_HERDR_READY_POLL=0 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -s "$cd_path/herdr_agent.txt" && ! -f "$cd_path/error.txt" ]]
check "a herdr with no readiness answer degrades to the retry backoff, not a hang" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null) stderr=$(cat "$t/err.txt")"

# --- the SHIPPED settle default, with the override unset -------------------
# The rest of this file collapses the settle to 0 for speed, which makes every other
# case blind to what the shipped default actually is: an empty or malformed value
# would make `sleep` fail (or spin) in production while every collapsed case passed.
# One case pays the real second.
t=$(new_env)
out=$(env -u HOTLINE_HERDR_PANE_SETTLE \
      PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -s "$cd_path/herdr_agent.txt" && ! -f "$cd_path/error.txt" ]]
check "the shipped HOTLINE_HERDR_PANE_SETTLE default is a usable sleep (override unset)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# --- failures leave a diagnosable call dir and no orphan pane --------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_START_FAIL=1 \
      HERDR_STUB_NEW_PANE="w1:p5" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -f "$cd_path/done" && -f "$cd_path/error.txt" ]] \
  && grep -q 'agent_start_failed' "$cd_path/error.txt"
check "a failed agent start writes error.txt + done and STILL returns the call_dir" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null)"
grep -q 'pane close w1:p5' <(tr -d '\\' < "$t/herdr.log")
check "…and closes the pane it opened, so a failed dial leaks nothing" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ ! -f "$cd_path/session_id.txt" ]]
check "…and writes NO session_id.txt (nothing booted, so nothing to promote)" $? \
  "call_dir: $(ls "$cd_path" | tr '\n' ' ')"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_READY=false \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
grep -q 'interactive_ready:false' "$cd_path/error.txt" 2>/dev/null
check "interactive_ready:false is a FAILURE, not a start (the field beats the exit code)" $? \
  "error=$(cat "$cd_path/error.txt" 2>/dev/null)"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_NO_PANES=1 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.error' <<<"$out" 2>/dev/null)" == *"no herdr pane"* ]]
check "no pane at all → a plain error, no call dir minted" $? "rc=$rc out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" --resume "some-session" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.error' <<<"$out" 2>/dev/null)" == *"cannot re-host an existing claude session"* ]]
check "--resume is refused, rather than presetting a session id claude would reject" $? \
  "rc=$rc out=$out"
# The refusal must not send a reader down the follow-up path: re-targeting a live
# agent is a different verb that launches nothing, and conflating the two is how a
# caller ends up believing a fresh callee carries the prior conversation.
[[ "$(jq -r '.error' <<<"$out" 2>/dev/null)" == *"re-targeted by name"* ]]
check "…and points at the re-target verb instead of implying a resume would work" $? "out=$out"

# --- herdr's observation outranks our preset -------------------------------
t=$(new_env)
OBS="dddddddd-1111-4111-8111-999999999999"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_OBSERVED_SID="$OBS" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ "$(cat "$cd_path/session_id.txt")" == "$OBS" \
   && "$(cat "$cd_path/session_id_preset.txt")" != "$OBS" ]]
check "an OBSERVED session id different from the preset wins (the transcript path depends on it)" $? \
  "session_id=$(cat "$cd_path/session_id.txt" 2>/dev/null) preset=$(cat "$cd_path/session_id_preset.txt" 2>/dev/null)"
[[ -s "$cd_path/session_id_mismatch.txt" ]]
check "…and the disagreement is recorded rather than swallowed" $? \
  "call_dir: $(ls "$cd_path" | tr '\n' ' ')"

# ===========================================================================
echo ""
echo "2b. Placement: a split, a tab, or a tab in a named group workspace:"
# ===========================================================================
# WHY THIS EXISTS. Every callee used to be a SPLIT off the anchor pane, so an
# orchestrator dialling 15 callees off one pane produced one tab holding 17
# slivers — unreadable, and the leftmost panes unreachable. HOTLINE_HERDR_PLACEMENT
# buys a tab per callee, and a named workspace to group a run's callees into.

# --- the default is byte-identical to what shipped -------------------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HERDR_STUB_NEW_PANE="w1:p9" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"pane split --pane w1:p1 --direction right --cwd $(cd "$t/target" && pwd -P) --no-focus"* ]]
check "no placement named → still ONE pane split, argv unchanged" $? "herdr calls: $log"
! grep -q "tab create\|workspace list\|workspace create\|pane get" "$t/herdr.log" 2>/dev/null
check "…and no tab/workspace verb is reached at all" $? "herdr calls: $log"
[[ "$(cat "$cd_path/herdr_pane.txt" 2>/dev/null)" == "w1:p9" \
   && ! -f "$cd_path/herdr_tab.txt" && ! -f "$cd_path/herdr_workspace.txt" ]]
check "…and a split records no tab or workspace handle" $? \
  "call_dir: $(ls "$cd_path" | tr '\n' ' ')"
[[ "$(cat "$cd_path/herdr_placement.txt" 2>/dev/null)" == "split" ]]
check "…but DOES record the placement, so a reader never has to infer it" $? \
  "got '$(cat "$cd_path/herdr_placement.txt" 2>/dev/null)'"

# --- placement=tab: a tab in the anchor's own workspace --------------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w6:p1" HOTLINE_HERDR_PLACEMENT=tab \
      HERDR_STUB_TAB_PANE="w6:p12" HERDR_STUB_TAB_ID="w6:t4" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ -n "$cd_path" && ! -f "$cd_path/error.txt" ]]
check "placement=tab launches without error" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null) stderr=$(cat "$t/err.txt")"
[[ "$log" == *"pane get w6:p1"* ]]
check "…asks herdr which workspace OWNS the anchor pane" $? "herdr calls: $log"
[[ "$log" == *"tab create --workspace w6 --cwd $(cd "$t/target" && pwd -P)"* ]]
check "…creates the tab in THAT workspace, in the callee's canonical cwd" $? "herdr calls: $log"
[[ "$log" == *"tab create"*"--no-focus"* ]]
check "…with --no-focus (a booting callee must not hold the user's cursor)" $? "herdr calls: $log"
! grep -q "pane split" "$t/herdr.log" 2>/dev/null
check "…and NEVER splits the anchor pane" $? "herdr calls: $log"
[[ "$(cat "$cd_path/herdr_pane.txt" 2>/dev/null)" == "w6:p12" ]]
check "herdr_pane.txt names the new tab's ROOT PANE" $? \
  "got '$(cat "$cd_path/herdr_pane.txt" 2>/dev/null)'"
agent=$(cat "$cd_path/herdr_agent.txt" 2>/dev/null || true)
[[ "$log" == *"agent start $agent --kind claude --pane w6:p12"* ]]
check "…and agent start targets that pane, not the anchor" $? "herdr calls: $log"
[[ "$(cat "$cd_path/herdr_tab.txt" 2>/dev/null)" == "w6:t4" \
   && "$(cat "$cd_path/herdr_workspace.txt" 2>/dev/null)" == "w6" \
   && "$(cat "$cd_path/herdr_placement.txt" 2>/dev/null)" == "tab" ]]
check "records tab/workspace/placement, so a caller can label, move or close later" $? \
  "tab='$(cat "$cd_path/herdr_tab.txt" 2>/dev/null)' ws='$(cat "$cd_path/herdr_workspace.txt" 2>/dev/null)' placement='$(cat "$cd_path/herdr_placement.txt" 2>/dev/null)'"

# --- the default label: unique token FIRST, ≤20 chars ----------------------
nonce=$(cat "$cd_path/call_id.txt" 2>/dev/null || true)
label=$(sed -n 's/.*--label \([^ ]*\).*/\1/p' <<<"$log" | head -1)
[[ -n "$label" && ${#label} -le 20 ]]
check "the default tab label fits herdr's sidebar (≤20 chars)" $? "label='$label' (${#label} chars)"
[[ "$label" == "${nonce: -6}-"* ]]
check "…leads with the call nonce's last 6, since the sidebar truncates the TAIL" $? \
  "label='$label' nonce='$nonce'"
[[ "$label" == *"target"* ]]
check "…and still carries the target directory after it" $? "label='$label'"

# --- an explicit label wins ------------------------------------------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w6:p1" HOTLINE_HERDR_PLACEMENT=tab \
      HOTLINE_HERDR_TAB_LABEL="boss-1-review" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"--label boss-1-review"* ]]
check "HOTLINE_HERDR_TAB_LABEL is used verbatim" $? "herdr calls: $log"

# --- --label: the SUBJECT, behind the nonce that has to lead -----------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w6:p1" HOTLINE_HERDR_PLACEMENT=tab \
      HERDR_STUB_TAB_PANE="w6:p12" HERDR_STUB_TAB_ID="w6:t4" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" --label "fix 500s" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
nonce=$(cat "$cd_path/call_id.txt" 2>/dev/null || true)
label=$(sed -n 's/.*--label \([^ ]*\).*/\1/p' <<<"$log" | head -1)
[[ "$label" == "${nonce: -6}-fix-500s" ]]
check "--label becomes the tab label, slugged, behind the call nonce" $? \
  "label='$label' nonce='$nonce'"
[[ ${#label} -le 20 ]]
check "…still inside herdr's ~20-char sidebar budget" $? "label='$label' (${#label} chars)"

# THE AGENT NAME IS NOT THE LABEL. Slugging a session-ish string into the agent
# name gave every agent in `herdr agent list` the same `hotline-hotline-*` and
# said nothing about which directory its callee sat in (claude-plugins-hukk).
agent=$(cat "$cd_path/herdr_agent.txt" 2>/dev/null || true)
[[ "$agent" == "hotline-$(basename "$t/target")-"* && "$agent" != *"fix"* ]]
check "…while the agent name stays the TARGET's dir slug, untouched by the label" $? \
  "agent='$agent' (expected hotline-$(basename "$t/target")-*)"

# A label long enough to blow the budget is truncated, not dropped — and the nonce
# still leads, because the sidebar clips the TAIL.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w6:p1" HOTLINE_HERDR_PLACEMENT=tab \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" \
        --label "audit the entire release runbook end to end" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
nonce=$(cat "$cd_path/call_id.txt" 2>/dev/null || true)
label=$(sed -n 's/.*--label \([^ ]*\).*/\1/p' <<<"$log" | head -1)
[[ "$label" == "${nonce: -6}-"* && ${#label} -le 20 ]]
check "an over-long label is truncated to the budget with the nonce still leading" $? \
  "label='$label' (${#label} chars) nonce='$nonce'"

# HOTLINE_HERDR_TAB_LABEL still outranks --label: it is the escape hatch for a
# shape the standard one does not offer, nonce lead included.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w6:p1" HOTLINE_HERDR_PLACEMENT=tab \
      HOTLINE_HERDR_TAB_LABEL="boss-1-review" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" --label "fix 500s" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"--label boss-1-review"* && "$log" != *"fix-500s"* ]]
check "HOTLINE_HERDR_TAB_LABEL outranks --label" $? "herdr calls: $log"

# A SPLIT has no tab of its own, so the label cannot name one there — it reaches
# the pane's TERMINAL TITLE instead, through the session name. CONTRACT GUARD on
# the first half: a split must never create or rename a tab, because the only tab
# in reach is the caller's.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" --label "fix 500s" \
        --name "hotline: fix 500s (work_order)" 2>/dev/null)
! grep -q "tab create\|tab rename" "$t/herdr.log" 2>/dev/null
check "a split placement creates and renames no tab for its label" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# --- --name reaches `claude -n`, which IS how a split pane gets named ---------
# claude publishes its session name as the terminal title and herdr renders that
# live, so a pane with no tab still reads `hotline: <label> (<mode>)`. The launcher
# built CLAUDE_ARGS with no `-n` at all before, which left a split naming nothing.
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"-n hotline: fix 500s (work_order)"* ]]
check "--name is forwarded to the callee's claude as -n, verbatim" $? "herdr calls: $log"
# THE AGENT NAME IS NOT THE SESSION NAME. Slugging a session-ish string into the
# agent name gives every call in a run the same slug, which is the one thing that
# name exists not to be (claude-plugins-hukk).
agent=$(sed -n 's/.*agent start \([^ ]*\).*/\1/p' <<<"$log" | head -1)
[[ "$agent" == hotline-target-* ]]
check "…while the agent name stays the TARGET's dir slug, untouched by it" $? \
  "agent='$agent'"

# NO --name: no `-n`, rather than an empty one that would title the pane "".
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
! grep -q -- ' -n ' <(tr -d '\\' < "$t/herdr.log")
check "no --name passes no -n at all" $? "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# --- placement=workspace, label ABSENT: create it, then tab into it --------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      HOTLINE_HERDR_PLACEMENT=workspace HOTLINE_HERDR_WORKSPACE="agentic-run-boss-group-1" \
      HERDR_STUB_WORKSPACES="w19:agentic-run-boss w1H:run-cli-38" \
      HERDR_STUB_NEW_WS="w22" HERDR_STUB_TAB_PANE="w22:p3" HERDR_STUB_TAB_ID="w22:t2" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ -n "$cd_path" && ! -f "$cd_path/error.txt" ]]
check "placement=workspace with an unknown label launches without error" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null) stderr=$(cat "$t/err.txt")"
[[ "$log" == *"workspace list"* && "$log" == *"workspace create --label agentic-run-boss-group-1"* ]]
check "…looks the label up, then creates the workspace it could not find" $? "herdr calls: $log"
[[ "$log" == *"tab create --workspace w22"* ]]
check "…and puts the callee's tab in the NEW workspace" $? "herdr calls: $log"
[[ "$(cat "$cd_path/herdr_workspace.txt" 2>/dev/null)" == "w22" \
   && "$(cat "$cd_path/herdr_placement.txt" 2>/dev/null)" == "workspace" ]]
check "…recording the group's workspace id" $? \
  "ws='$(cat "$cd_path/herdr_workspace.txt" 2>/dev/null)'"
! grep -q "pane split" "$t/herdr.log" 2>/dev/null
check "…and still never splits the anchor" $? "herdr calls: $log"

# --- placement=workspace, label PRESENT: join it, create nothing -----------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      HOTLINE_HERDR_PLACEMENT=workspace HOTLINE_HERDR_WORKSPACE="run-cli-38" \
      HERDR_STUB_WORKSPACES="w19:agentic-run-boss w1H:run-cli-38" \
      HERDR_STUB_TAB_PANE="w1H:p8" HERDR_STUB_TAB_ID="w1H:t8" \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
! grep -q "workspace create" "$t/herdr.log" 2>/dev/null
check "an EXISTING group label is joined, never re-created" $? "herdr calls: $log"
[[ "$log" == *"tab create --workspace w1H"* \
   && "$(cat "$cd_path/herdr_workspace.txt" 2>/dev/null)" == "w1H" ]]
check "…and the tab lands in the workspace that already carried that label" $? \
  "herdr calls: $log ws='$(cat "$cd_path/herdr_workspace.txt" 2>/dev/null)'"

# --- two callees, one group: the second joins the first's workspace ---------
# The orchestrator's actual shape. A second dial with the same label must not
# mint a second workspace, or a "group" is one workspace per member.
t=$(new_env)
env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
    HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
    HOTLINE_HERDR_PLACEMENT=workspace HOTLINE_HERDR_WORKSPACE="grp" \
    HERDR_STUB_WORKSPACES="w7:grp" HERDR_STUB_TAB_PANE="w7:p2" \
    bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "one" >/dev/null 2>&1
env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
    HERDR_STATE="$t/state2" HERDR_PANE_ID="w1:p1" \
    HOTLINE_HERDR_PLACEMENT=workspace HOTLINE_HERDR_WORKSPACE="grp" \
    HERDR_STUB_WORKSPACES="w7:grp" HERDR_STUB_TAB_PANE="w7:p3" \
    bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "two" >/dev/null 2>&1
[[ "$(grep -c 'tab create' "$t/herdr.log")" -eq 2 \
   && "$(grep -c 'workspace create' "$t/herdr.log" 2>/dev/null || true)" -eq 0 ]]
check "two dials into one group label → two tabs, ONE workspace" $? \
  "tab creates: $(grep -c 'tab create' "$t/herdr.log") ws creates: $(grep -c 'workspace create' "$t/herdr.log" 2>/dev/null || echo 0)"

# --- usage errors are refused BEFORE any state exists ----------------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HOTLINE_HERDR_PLACEMENT=window \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.error' <<<"$out" 2>/dev/null)" == *"split|tab|workspace"* ]]
check "an unknown HOTLINE_HERDR_PLACEMENT is refused, naming the three it accepts" $? \
  "rc=$rc out=$out"
[[ ! -f "$t/herdr.log" ]]
check "…before a single herdr call is made" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" HOTLINE_HERDR_PLACEMENT=workspace \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null); rc=$?
[[ $rc -ne 0 && "$(jq -r '.error' <<<"$out" 2>/dev/null)" == *"HOTLINE_HERDR_WORKSPACE"* ]]
check "placement=workspace with no group label is refused, naming the variable" $? \
  "rc=$rc out=$out"

# --- a tab that could not be made is a failed dial, cleaned up -------------
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w6:p1" HOTLINE_HERDR_PLACEMENT=tab \
      HERDR_STUB_TAB_FAIL=1 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && -f "$cd_path/done" \
   && "$(jq -r '.error' < "$cd_path/error.txt" 2>/dev/null)" == *"tab create"* ]]
check "a tab create failure writes error.txt + done and still returns a call_dir" $? \
  "out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null)"

# A failed launch in a TAB closes the TAB, not just its pane — and never the
# group workspace, which the callee's siblings are living in.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      HOTLINE_HERDR_PLACEMENT=workspace HOTLINE_HERDR_WORKSPACE="grp" \
      HERDR_STUB_WORKSPACES="w7:grp" HERDR_STUB_TAB_ID="w7:t9" \
      HERDR_STUB_START_FAIL=1 \
      bash "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi" 2>/dev/null)
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"tab close w7:t9"* ]]
check "a failed agent start closes the TAB it created" $? "herdr calls: $log"
! grep -q "workspace close" "$t/herdr.log" 2>/dev/null
check "…and never the group workspace its siblings are living in" $? "herdr calls: $log"

# ===========================================================================
echo ""
echo "8. Doc canaries — a stated default has one source:"
# ===========================================================================
# SKILL.md states these numbers, and the scripts define them. Two copies of a
# constant is how a documented "default 60" sat next to a hardcoded 20 at both call
# sites, so each restatement gets a canary rather than trust.
DIAL_SKILL="$HOTLINE_DIR/skills/dial/SKILL.md"
# Flattened: the doc wraps its bullets, so the variable and its stated default are
# on different LINES. A line-oriented grep would silently never match and the canary
# would assert nothing.
SKILL_FLAT=$(tr '\n' ' ' < "$DIAL_SKILL" | tr -s ' ')

[[ "$SKILL_FLAT" == *'HOTLINE_HERDR_SPLIT_DIRECTION=right|down`** — which way a `split` placement goes (default `right`)'* ]] \
  && grep -q 'HOTLINE_HERDR_SPLIT_DIRECTION:-right' "$HERDR_ASYNC"
check "SKILL.md's split-direction default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_SPLIT_DIRECTION:-[a-z]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'HOTLINE_HERDR_PLACEMENT=split|tab|workspace`** — where the callee'* \
   && "$SKILL_FLAT" == *'(default `split`, a sibling of the anchor pane)'* ]] \
  && grep -q 'HOTLINE_HERDR_PLACEMENT:-split}' "$HERDR_ASYNC"
check "SKILL.md's placement default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_PLACEMENT:-[a-z]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'freshly split pane (default 1)'* ]] \
  && grep -q 'HOTLINE_HERDR_PANE_SETTLE:-1}' "$HERDR_ASYNC"
check "SKILL.md's pane-settle default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_PANE_SETTLE:-[0-9]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'retrying a busy start (default 30)'* ]] \
  && grep -q 'HOTLINE_HERDR_START_BUDGET:-30}' "$HERDR_ASYNC"
check "SKILL.md's start-budget default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_START_BUDGET:-[0-9]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'re-reads the pane (default 0.5)'* ]] \
  && grep -q 'HOTLINE_HERDR_READY_POLL:-0.5}' "$HERDR_ASYNC"
check "SKILL.md's readiness-poll default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_READY_POLL:-[0-9.]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'reports the pane ready (default 4)'* ]] \
  && grep -q 'HOTLINE_HERDR_START_ATTEMPTS:-4}' "$HERDR_ASYNC"
check "SKILL.md's start-attempts default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_START_ATTEMPTS:-[0-9]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'is really `blocked` (default 1)'* ]] \
  && grep -q 'HOTLINE_HERDR_BLOCKED_SETTLE:-1}' "$HERDR_REUSE"
check "SKILL.md's blocked-settle default matches herdr-reuse-agent.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_BLOCKED_SETTLE:-[0-9]*' "$HERDR_REUSE")"

[[ "$SKILL_FLAT" == *'re-reads the transcript (default 30000)'* ]] \
  && grep -q 'HOTLINE_HERDR_WAIT_SLICE_MS:-30000}' "$WAIT_RESPONSE"
check "SKILL.md's wait-slice default matches wait-for-response.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_WAIT_SLICE_MS:-[0-9]*' "$WAIT_RESPONSE")"

[[ "$SKILL_FLAT" == *'FIRST delivery into that agent (default 1)'* ]] \
  && grep -q 'HOTLINE_HERDR_FIRST_SETTLE:-1}' "$HERDR_PROMPT"
check "SKILL.md's first-contact settle default matches herdr-prompt.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_FIRST_SETTLE:-[0-9]*' "$HERDR_PROMPT")"

[[ "$SKILL_FLAT" == *'`blocked` state (default 20,'* ]] \
  && grep -q 'HOTLINE_HERDR_READY_TRIES:-20}' "$HERDR_PROMPT"
check "SKILL.md's readiness-tries default matches herdr-prompt.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_READY_TRIES:-[0-9]*' "$HERDR_PROMPT")"

[[ "$SKILL_FLAT" == *'for a FIRST delivery (default 40,'* ]] \
  && grep -q 'HOTLINE_HERDR_FIRST_CONFIRM_TRIES:-40}' "$HERDR_PROMPT"
check "SKILL.md's first-contact confirm budget matches herdr-prompt.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_FIRST_CONFIRM_TRIES:-[0-9]*' "$HERDR_PROMPT")"

# The remote knobs' defaults, same rule: a doc that states a number states one the
# code agrees with, or it is a second source that drifts.
[[ "$SKILL_FLAT" == *"floor on each ssh hop's budget (default 60)"* ]] \
  && grep -q 'HOTLINE_REMOTE_SSH_TIMEOUT:-60}' "$HOTLINE_DIR/scripts/herdr-remote.sh"
check "SKILL.md's ssh-hop budget default matches herdr-remote.sh" $? \
  "script: $(grep -o 'HOTLINE_REMOTE_SSH_TIMEOUT:-[0-9]*' "$HOTLINE_DIR/scripts/herdr-remote.sh")"

[[ "$SKILL_FLAT" == *"outlives the last hop (default 300)"* ]] \
  && grep -q 'HOTLINE_REMOTE_SSH_PERSIST:-300}' "$HOTLINE_DIR/scripts/herdr-remote.sh"
check "SKILL.md's ControlPersist default matches herdr-remote.sh" $? \
  "script: $(grep -o 'HOTLINE_REMOTE_SSH_PERSIST:-[0-9]*' "$HOTLINE_DIR/scripts/herdr-remote.sh")"

[[ "$SKILL_FLAT" == *"own connect budget (default 10)"* ]] \
  && grep -q 'HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT:-10}' "$HOTLINE_DIR/scripts/herdr-remote.sh"
check "SKILL.md's ssh connect-timeout default matches herdr-remote.sh" $? \
  "script: $(grep -o 'HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT:-[0-9]*' "$HOTLINE_DIR/scripts/herdr-remote.sh")"

# A herdr error hint must point at the section that actually covers herdr, not at
# the cmux one — an error hint naming the wrong section is worse than none.
grep -q '## herdr Failures' "$HOTLINE_DIR/skills/dial/references/error-recovery.md" \
  && grep -q '## Remote herdr Failures' "$HOTLINE_DIR/skills/dial/references/error-recovery.md"
check "error-recovery.md has both § herdr Failures sections the hints name" $? \
  "sections: $(grep -c '^## ' "$HOTLINE_DIR/skills/dial/references/error-recovery.md")"

herdr_suite_finish
