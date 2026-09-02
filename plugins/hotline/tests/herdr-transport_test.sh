#!/usr/bin/env bash
# =============================================================================
# Regression tests for the herdr transport backend (Phase 1: detached, local).
#
# herdr is hotline's third backend behind one call-dir contract, and it differs
# from cmux in ways that are easy to get subtly wrong. These tests pin the ones
# that matter:
#
#   1. PREFLIGHT is three separate questions — binary, server, splittable pane —
#      and each has its own actionable reason. A caller who is told "upgrade
#      herdr" when the real problem is "no server is running" is being misled.
#   2. THE LAUNCHER IS SYNCHRONOUS. `herdr agent start` blocks until the agent is
#      interactive-ready, so herdr-call-async.sh writes session_id.txt ITSELF.
#      Everything downstream (boot wait, delivery, response wait) depends on that
#      being true, and on the rest of the call-dir contract being byte-compatible
#      with what the cmux launcher produces.
#   3. herdr's OBSERVED session id outranks our preset. The transcript path is
#      derived from the session id, so a `--session-id` passthrough that silently
#      did not take would make every later read miss — forever, and quietly.
#   4. SELECTION IS EXPLICIT AND NEVER DEGRADES TO cmux. `--transport herdr` is an
#      ask for a callee that outlives a disconnect; answering it with a cmux
#      surface would be a lie that only surfaces hours later. A failed preflight
#      is an ERROR, and the placements/modes herdr cannot host are REFUSED with
#      the phase that will lift the restriction.
#   5. THE WAITERS REUSE transcript-extract.sh UNCHANGED. herdr's lifecycle states
#      replace the poll GATE, not the answer: the same nonce/STATUS bracketing and
#      the same 0/3/4 exit contract. And there is NO screen fallback — a claude
#      REPL is an alternate-screen TUI — so an unconfirmable call must report that
#      rather than scrape something weaker.
#
# Nothing here touches a real herdr, a real cmux, a real claude, or any beads DB:
# `herdr`, `cmux` and `claude` are PATH stubs, HOME is a sandbox, and
# HOTLINE_CALL_HOME points every call dir at a directory this suite owns and wipes.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$HOTLINE_DIR/skills/dial/scripts"
CHECK_HERDR="$SCRIPTS/check-herdr.sh"
HERDR_ASYNC="$SCRIPTS/herdr-call-async.sh"
HERDR_PROMPT="$SCRIPTS/herdr-prompt.sh"
WAIT_SESSION="$SCRIPTS/wait-for-session.sh"
WAIT_RESPONSE="$SCRIPTS/wait-for-response.sh"
DIAL="$SCRIPTS/dial.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}
check() {  # check <label> <rc> <diagnostic>
  if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

# ---------------------------------------------------------------------------
# Poison stubs in FRONT of PATH for the whole file. A case that forgets its own
# stub fails loudly here instead of reaching the developer's real herdr and
# splitting a live pane (or worse, starting a real claude in it).
# ---------------------------------------------------------------------------
ROOT="$(mktemp -d /tmp/hotline-herdr-test-XXXXXX)"
POISON_BIN="$ROOT/poison-bin"
POISON_LOG="$ROOT/violations"
mkdir -p "$POISON_BIN"
for _poison in herdr cmux claude dirmap; do
  cat > "$POISON_BIN/$_poison" <<POISON
#!/usr/bin/env bash
echo "$_poison \$*" >> "$POISON_LOG"
echo "TEST BUG: reached the real $_poison — this invocation is missing its PATH stub" >&2
exit 127
POISON
  chmod +x "$POISON_BIN/$_poison"
done
PATH="$POISON_BIN:$PATH"

export HOTLINE_CALL_HOME="$ROOT/calls"
mkdir -p "$HOTLINE_CALL_HOME"
# The whole suite runs with the settle sleep and poll cadence collapsed: the
# launcher's retry logic and the waiter's loop are exercised for their DECISIONS,
# not their wall-clock. (The waiter accounts its budget in fixed integer ticks, so
# this changes neither the iteration count nor any branch it takes.)
export HOTLINE_HERDR_PANE_SETTLE=0
export HOTLINE_POLL_SLEEP=0
export HOTLINE_PASTE_CONFIRM_TRIES=2
export HOTLINE_PASTE_CONFIRM_SLEEP=0.05
# The caller may itself be running inside herdr (this suite's own session often
# is). Strip that so pane resolution is decided by the case, not the machine — and
# strip the hotline opt-ins for the same reason: a developer with
# HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS exported in their shell would otherwise see
# the "off by default" assertions pass or fail depending on their environment.
unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID \
      HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS HOTLINE_CLAUDE_MODEL \
      HOTLINE_HERDR_PANE HOTLINE_HERDR_SPLIT_DIRECTION 2>/dev/null || true

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The herdr stub. One script for every case, shaped by env:
#
#   HERDR_LOG                 append every invocation here (required)
#   HERDR_STATE               scratch dir the stub keeps its own memory in
#   HERDR_STUB_SESSION_RC     exit code for `session list` (0 = a server is up)
#   HERDR_STUB_NO_PANES=1     `pane list` reports an empty pane array
#   HERDR_STUB_PANE           the pane `pane list` reports (default w1:p1)
#   HERDR_STUB_NEW_PANE       the pane `pane split` returns (default w1:p9)
#   HERDR_STUB_SPLIT_FAIL=1   `pane split` returns a server error
#   HERDR_STUB_BUSY_TIMES=N   the first N `agent start` calls fail agent_pane_busy
#   HERDR_STUB_START_FAIL=1   `agent start` fails with a non-retryable error
#   HERDR_STUB_READY=false    `agent start` reports interactive_ready:false
#   HERDR_STUB_OBSERVED_SID   the session id `agent start`/`agent get` report
#                             (default: whatever --session-id we were handed)
#   HERDR_STUB_AGENT_GONE=1   `agent get` answers agent_not_found (as the real CLI
#                             does — ON STDOUT, WITH EXIT 0)
#   HERDR_STUB_AGENT_ANY=1    `agent get` resolves any name (for waiter cases whose
#                             agent was never "started" through this stub)
#   HERDR_STUB_STATUS         the agent_status `agent get` reports (default idle)
#   HERDR_STUB_PROMPT_FAIL=1  `agent prompt` returns a server error
#   HERDR_STUB_TRANSCRIPT     `agent prompt` appends a realistic user record
#                             carrying the prompt text to this .jsonl (i.e. the
#                             callee recording what it received)
#   HERDR_STUB_WAIT_RC        exit code for `agent wait` (default 0)
# ---------------------------------------------------------------------------
make_herdr_stub() {  # <bin-dir>
  mkdir -p "$1"
  cat > "$1/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "${HERDR_LOG:?HERDR_LOG not set}"; printf '\n' >> "$HERDR_LOG"
ST="${HERDR_STATE:-/tmp}"
mkdir -p "$ST"
err() { printf '{"error":{"code":"%s","message":"%s"},"id":"cli:stub"}\n' "$1" "$2"; exit 0; }

case "$1 ${2:-}" in
  "session list")
    echo "name status directory socket"
    exit "${HERDR_STUB_SESSION_RC:-0}" ;;

  "pane list")
    if [[ "${HERDR_STUB_NO_PANES:-}" == "1" ]]; then
      jq -nc '{id:"cli:pane:list",result:{panes:[],type:"pane_list"}}'
    else
      jq -nc --arg p "${HERDR_STUB_PANE:-w1:p1}" \
        '{id:"cli:pane:list",result:{panes:[{pane_id:$p,cwd:"/tmp"}],type:"pane_list"}}'
    fi
    exit 0 ;;

  "pane split")
    [[ "${HERDR_STUB_SPLIT_FAIL:-}" == "1" ]] && err pane_split_failed "no room to split"
    jq -nc --arg p "${HERDR_STUB_NEW_PANE:-w1:p9}" \
      '{id:"cli:pane:split",result:{pane:{pane_id:$p}}}'
    exit 0 ;;

  "pane close") echo '{"id":"cli:pane:close","result":{"closed":true}}'; exit 0 ;;

  "agent start")
    NAME="$3"
    # Retryable race: a freshly split pane whose shell is not at its prompt yet.
    BUSY="${HERDR_STUB_BUSY_TIMES:-0}"
    SEEN=0; [[ -f "$ST/busy" ]] && SEEN=$(cat "$ST/busy")
    if [[ "$SEEN" -lt "$BUSY" ]]; then
      echo $((SEEN + 1)) > "$ST/busy"
      printf '{"error":{"code":"agent_pane_busy","message":"pane is not at an interactive prompt"}}\n' >&2
      exit 1
    fi
    [[ "${HERDR_STUB_START_FAIL:-}" == "1" ]] && err agent_start_failed "claude was not detected in the pane"
    # The session id claude was told to use — the passthrough under test.
    SID=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--session-id" ]] && { SID="$2"; break; }
      shift
    done
    printf '%s' "$SID" > "$ST/session_id"
    printf '%s' "$NAME" >> "$ST/started"
    printf '\n' >> "$ST/started"
    jq -nc --arg n "$NAME" --arg sid "${HERDR_STUB_OBSERVED_SID:-$SID}" \
           --arg ready "${HERDR_STUB_READY:-true}" \
      '{id:"cli:agent:start",result:{agent:{name:$n,agent:"claude",
         interactive_ready:($ready == "true"),agent_status:"idle",
         agent_session:{agent:"claude",kind:"id",source:"herdr:claude",value:$sid}}}}'
    exit 0 ;;

  "agent get")
    NAME="$3"
    [[ "${HERDR_STUB_AGENT_GONE:-}" == "1" ]] && err agent_not_found "agent target $NAME not found"
    if [[ "${HERDR_STUB_AGENT_ANY:-}" != "1" ]]; then
      grep -qxF "$NAME" "$ST/started" 2>/dev/null \
        || err agent_not_found "agent target $NAME not found"
    fi
    SID="${HERDR_STUB_OBSERVED_SID:-$(cat "$ST/session_id" 2>/dev/null || true)}"
    jq -nc --arg n "$NAME" --arg s "${HERDR_STUB_STATUS:-idle}" --arg sid "$SID" \
      '{id:"cli:agent:get",result:{agent:{name:$n,agent:"claude",agent_status:$s,
         interactive_ready:true,
         agent_session:{agent:"claude",kind:"id",source:"herdr:claude",value:$sid}}}}'
    exit 0 ;;

  "agent prompt")
    [[ "${HERDR_STUB_PROMPT_FAIL:-}" == "1" ]] && err agent_prompt_failed "no such agent"
    if [[ -n "${HERDR_STUB_TRANSCRIPT:-}" ]]; then
      mkdir -p "$(dirname "$HERDR_STUB_TRANSCRIPT")"
      jq -nc --arg t "$4" --arg sid "$(cat "$ST/session_id" 2>/dev/null || echo stub-session)" \
        '{type:"user",isSidechain:false,sessionId:$sid,message:{content:$t}}' \
        >> "$HERDR_STUB_TRANSCRIPT"
    fi
    echo '{"id":"cli:agent:prompt","result":{"submitted":true}}'
    exit 0 ;;

  "agent wait")
    echo '{"id":"cli:agent:wait","result":{"agent":{"agent_status":"done"}}}'
    exit "${HERDR_STUB_WAIT_RC:-0}" ;;

  *) echo '{"id":"cli:stub","result":{}}'; exit 0 ;;
esac
STUB
  chmod +x "$1/herdr"
}

# A cmux stub that FAILS every ping, so a case which accidentally reaches the cmux
# selection chain lands on headless rather than on the developer's live cmux.
make_cmux_stub() {  # <bin-dir>
  mkdir -p "$1"
  cat > "$1/cmux" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CMUX_LOG:-/dev/null}"
exit 1
STUB
  chmod +x "$1/cmux"
}

# Encode a cwd the way Claude Code does when deriving its project directory.
encode_cwd() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9]|-|g'; }

# A transcript that carries a nonce and, optionally, a terminal STATUS.
transcript_with() {  # <file> <nonce> <status|''> <body>
  local f="$1" nonce="$2" status="$3" body="$4"
  mkdir -p "$(dirname "$f")"
  {
    printf '{"type":"user","isSidechain":false,"sessionId":"herdr-sess","message":{"content":"[CALL_ID: %s] do the thing"}}\n' "$nonce"
    if [[ -n "$status" ]]; then
      printf '{"type":"assistant","isSidechain":false,"sessionId":"herdr-sess","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id=%s\\n%s\\nSTATUS: %s call_id=%s"}]}}\n' \
        "$nonce" "$body" "$status" "$nonce"
    else
      printf '{"type":"assistant","isSidechain":false,"sessionId":"herdr-sess","message":{"content":[{"type":"text","text":"STATUS: WORK_IN_PROGRESS call_id=%s\\n%s"}]}}\n' \
        "$nonce" "$body"
    fi
  } > "$f"
}

# A fresh scratch env: bin/ (stubs), home/ (sandbox HOME), target/ (callee cwd),
# state/ (the stub's memory), plus HERDR_LOG.
new_env() {
  local t
  t=$(mktemp -d "$ROOT/env-XXXXXX")
  mkdir -p "$t/bin" "$t/home" "$t/target" "$t/state" "$t/pending"
  make_herdr_stub "$t/bin"
  make_cmux_stub "$t/bin"
  # resolve-workspace.sh consults dirmap for fuzzy references. Every --target here
  # is an absolute path, so this should never be reached — a stub that finds
  # nothing keeps that true instead of trusting it.
  cat > "$t/bin/dirmap" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$t/bin/dirmap"
  printf '%s' "$t"
}

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
        --name "hotline: a → b (work_order)" --detached 2>"$t/err.txt")
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
[[ $rc -ne 0 && "$(jq -r '.error' <<<"$out" 2>/dev/null)" == *"first-contact only"* ]]
check "--resume is refused (Phase 2), rather than presetting a session id claude would reject" $? \
  "rc=$rc out=$out"

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
echo "3. Delivery (herdr-prompt.sh) — one proof tier, and no pretending:"
# ===========================================================================

t=$(new_env)
SID="herdr-deliver-1"
NONCE="ab12cd34ef56aa01"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nthe work order\n' "$NONCE" > "$t/payload.md"
mkdir -p "$t/state"; printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-x-1 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.confirmed' <<<"$out" 2>/dev/null)" == "transcript" ]]
check "nonce lands in the callee's transcript → delivered, confirmed:transcript" $? "out=$out"
grep -q 'agent prompt hotline-x-1' <(tr -d '\\' < "$t/herdr.log")
check "…submitted by AGENT NAME (no surface to resolve, no input box to prove)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
! grep -q -- '--wait' "$t/herdr.log" 2>/dev/null
check "…without --wait (a quietly thinking callee would return agent_prompt_stalled)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The symlinked-cwd case: the callee writes under the REALPATH encoding, so a
# confirmation derived only from the path we were handed would miss — silently.
t=$(new_env)
SID="herdr-deliver-2"
NONCE="bb22cc33dd44ee55"
LINKED="$t/link-to-target"
ln -s "$t/target" "$LINKED"
REAL_TRANS="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$REAL_TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-x-2 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$LINKED" --session "$SID" 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "a symlinked cwd is confirmed via the REALPATH transcript spelling too" $? "out=$out"

# --- the argv exposure boundary (claude-plugins-bwu1) -----------------------
# The repo rule is that payloads ride files or stdin, never argv (compounding.md,
# claude-plugins-86ka). herdr 0.8.0 offers no file or stdin form for a prompt, so
# this one delivery verb is the documented exception — and an exception is only
# scoped if its edge is pinned. The payload may appear in the `agent prompt` argv
# and NOWHERE else: not in a second herdr call, not in the status read that precedes
# it, not in the JSON this script emits.
t=$(new_env)
SID="herdr-argv-1"
NONCE="cc33dd44ee55ff66"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
SENTINEL="PAYLOAD-SENTINEL-DO-NOT-LEAK-9f3a"
printf '[CALL_ID: %s]\n%s\n' "$NONCE" "$SENTINEL" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-x-argv --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" 2>/dev/null)
[[ "$(grep -c "$SENTINEL" "$t/herdr.log" 2>/dev/null)" == "1" ]]
check "the payload reaches EXACTLY ONE herdr invocation (the argv exception, scoped)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(grep "$SENTINEL" "$t/herdr.log" 2>/dev/null)" == *"agent prompt"* ]]
check "…and that one is \`agent prompt\`, the verb with no file or stdin form" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$out" != *"$SENTINEL"* ]]
check "…and never the emitted JSON, which names the payload FILE instead" $? "out=$out"

t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_GONE=1 \
      bash "$HERDR_PROMPT" --agent hotline-x-3 --payload-file "$t/payload.md" \
        --call-id nonce3 --cwd "$t/target" --session s3 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a dead agent → delivered:false sent:FALSE (safe to re-dial: nobody got anything)" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and nothing is submitted after that check fails" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_PROMPT_FAIL=1 \
      bash "$HERDR_PROMPT" --agent hotline-x-4 --payload-file "$t/payload.md" \
        --call-id nonce4 --cwd "$t/target" --session s4 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a refused submit → sent:false (herdr validates before writing any bytes)" $? "out=$out"

t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_PROMPT" --agent hotline-x-5 --payload-file "$t/payload.md" \
        --call-id nonce5 --cwd "$t/target" --session s5 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no screen fallback"* ]]
check "submitted but never confirmed → sent:TRUE and an honest 'no screen fallback' reason" $? "out=$out"

# ===========================================================================
echo ""
echo "4. The waiters' herdr branch:"
# ===========================================================================

# A staged herdr call dir, as the launcher leaves one.
stage_herdr_dir() {  # <dir> <agent> <session> <nonce> <cwd>
  local d="$1"
  mkdir -p "$d"
  echo herdr      > "$d/transport.txt"
  echo "$2"       > "$d/herdr_agent.txt"
  echo "w1:p9"    > "$d/herdr_pane.txt"
  echo "$3"       > "$d/session_id.txt"
  echo "$3"       > "$d/session_id_preset.txt"
  echo "$4"       > "$d/call_id.txt"
  echo "$5"       > "$d/cwd.txt"
  echo true       > "$d/keep_workspace.txt"
  echo work_order > "$d/mode.txt"
  echo caller-77  > "$d/caller_session.txt"
  return 0
}

# --- wait-for-session ------------------------------------------------------
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-1 "herdr-sess" "n0001" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" \
      bash "$WAIT_SESSION" "$cd_path" --timeout 5 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$out" == "herdr-sess" ]]
check "wait-for-session (herdr) returns the id the launcher already wrote" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/cmux.log" ]]
check "…without a single cmux call" $? "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"
# session-cache.sh keys its connections by the REALPATH of the target.
REG="$t/home/.agents-hotline/sessions/caller-77.json"
[[ -s "$REG" ]] \
  && [[ "$(jq -r --arg t "$(cd "$t/target" && pwd -P)" '.connections[$t].surface_ref' \
            "$REG" 2>/dev/null)" == "hotline-w-1" ]]
check "…and registers the call with the AGENT NAME as the opaque host handle" $? \
  "registry: $(cat "$t/home/.agents-hotline/sessions/caller-77.json" 2>/dev/null)"

# The launcher-bug verdict: no agent name AND no error either. Nothing here says
# what went wrong, so the missing handle IS the diagnosis. The case below stages
# the same missing handle WITH the launcher's error beside it, and the two must
# reach opposite verdicts — that is the whole point of the ordering they pin.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-2 "s" "n" "$t/target"
rm -f "$cd_path/herdr_agent.txt"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" bash "$WAIT_SESSION" "$cd_path" --timeout 3 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'launcher bug' "$t/err.txt"
check "a herdr call dir with no agent name and no error fails loudly as a launcher bug" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# Staged the way fail_async ACTUALLY leaves the dir: herdr-call-async.sh writes
# herdr_agent.txt only after `agent start` succeeds, so a start that failed leaves
# error.txt + done and NO agent name. A fixture that kept the agent name modelled a
# state the launcher never produces, and so could not see the missing-handle guard
# firing ahead of the early-fail check and reporting herdr's own diagnostic — an
# agent_pane_busy among them — as a hotline launcher bug. (claude-plugins-r465.8: a
# fixture has to model the state the bug destroys.)
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-3 "s" "n" "$t/target"
rm -f "$cd_path/session_id.txt" "$cd_path/herdr_agent.txt"
echo '{"error":"herdr agent start failed in pane w1:p9 after 4 attempt(s): agent_pane_busy"}' > "$cd_path/error.txt"
touch "$cd_path/done"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" bash "$WAIT_SESSION" "$cd_path" --timeout 3 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'agent_pane_busy' "$t/err.txt"
check "a launcher failure keeps ITS diagnostic, not the missing-handle guard's" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
! grep -q 'launcher bug' "$t/err.txt"
check "…so the caller is never told 'launcher bug' about herdr's own refusal" $? \
  "stderr=$(cat "$t/err.txt")"

# The earliest failure of all: the pane split itself was refused, so the dir has
# neither an agent name nor a pane. Same verdict, and it is the shape the
# recovery advice in the guard's message would be most wrong about.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-w-4 "s" "n" "$t/target"
rm -f "$cd_path/session_id.txt" "$cd_path/herdr_agent.txt" "$cd_path/herdr_pane.txt"
echo '{"error":"herdr pane split from w1:p1 failed: pane_not_found"}' > "$cd_path/error.txt"
touch "$cd_path/done"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" bash "$WAIT_SESSION" "$cd_path" --timeout 3 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'pane_not_found' "$t/err.txt" && ! grep -q 'launcher bug' "$t/err.txt"
check "a refused pane split is reported as herdr said it, not as a missing handle" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# --- wait-for-response ----------------------------------------------------
t=$(new_env)
NONCE="ff00aa11bb22cc33"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-1 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "the answer is 42"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" HERDR_STUB_AGENT_ANY=1 \
      HOTLINE_POLL_SLEEP=0 bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"the answer is 42"* ]]
check "wait-for-response (herdr) extracts the answer via transcript-extract.sh" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.session_id' <<<"$out" 2>/dev/null)" == "herdr-sess" ]]
check "…reporting the callee's CLAUDE session id, not a herdr handle" $? "out=$out"
[[ ! -s "$t/cmux.log" ]]
check "…with no cmux call anywhere in it" $? "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"
! grep -q 'pane close' "$t/herdr.log" 2>/dev/null
check "…and nothing is closed: the agent outlives the call (that is why herdr exists)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- a herdr call dir NEVER file-watches to timeout (claude-plugins-r6jj) ----
# transport.sh accepts 'herdr' and this branch handles it, but the two are separate
# decisions, and the gap between them fails silently: a herdr dir that fell through
# to the host-handle inference has no handle to find, so it would take the headless
# file-watch path and poll a `done` nobody writes for the whole 1800s budget.
#
# Told apart by the failure they produce. The herdr branch names the agent and gives
# up inside FILE_GRACE; the file-watch path can only ever say "Timed out waiting for
# response", and only after the budget is gone. The generous --timeout is the point:
# the file-watch path would still be sleeping.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r6jj-a "herdr-sess" "n0r6jj" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" HERDR_STUB_AGENT_ANY=1 \
      HOTLINE_POLL_SLEEP=0 bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 \
      2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'hotline-r6jj-a' "$t/err.txt"
check "a herdr call dir with no host handle fails as herdr, naming the agent" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
! grep -q 'Timed out waiting for response' "$t/err.txt"
check "…never as the headless file-watch, which would sit on \`done\` for the budget" $? \
  "stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/cmux.log" ]]
check "…and asks cmux nothing on the way out" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The other half of the same gap: WITH a handle present the inference reads cmux, so
# a stale one must not be able to pull a herdr call onto the cmux path.
#
# Both paths read the transcript first, so a finished call cannot tell them apart.
# An UNFINISHED one can: the gate is what differs. herdr blocks on `herdr agent
# wait`; the cmux path asks cmux about the callee's screen and input box. So the
# transcript below carries the nonce with no terminal STATUS, and the evidence is
# which CLI got asked.
t=$(new_env)
NONCE="d00dd00dd00dd00d"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r6jj-b "herdr-sess" "$NONCE" "$t/target"
echo "workspace:99" > "$cd_path/workspace_ref.txt"
echo "/tmp/hotline-launch-FAKE-$$" > "$cd_path/launch_script.txt"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" HERDR_STUB_AGENT_ANY=1 \
      HERDR_STUB_STATUS=working HOTLINE_POLL_SLEEP=0 \
      HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 6 2>"$t/err.txt"); rc=$?
grep -q 'agent wait hotline-r6jj-b' <(tr -d '\\' < "$t/herdr.log")
check "a stale cmux handle never diverts a herdr call off the \`agent wait\` gate" $? \
  "rc=$rc herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ ! -s "$t/cmux.log" ]]
check "…and cmux is asked nothing about a herdr callee's screen" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The answer was already on disk, so the gate must not have been the thing that
# decided anything — but when it IS reached it must ask for the settled SET.
# `--until idle` alone would hang forever on a hotline callee: herdr reports an
# unfocused finished agent as `done`, not `idle`.
# --- the live-caught blocker: cwd.txt in one spelling, transcript in the other ---
# Delivery has always tried BOTH spellings of the callee's cwd; the wait derived only
# the literal one. Live consequence on a real callee under /tmp/herdr-live-smoke:
# `herdr-prompt.sh` confirmed the nonce, then the wait exited 1 with "the prompt never
# reached the agent" while STATUS: WORK_COMPLETE sat in the realpath-encoded
# transcript. Every fixture above uses an already-canonical path, which is exactly why
# none of them could see it.
t=$(new_env)
NONCE="cafe1234beef5678"
LINKED_CWD="$t/symlinked-target"
ln -s "$t/target" "$LINKED_CWD"
cd_path="$t/call"
# cwd.txt holds the SYMLINKED path — what an older call dir, or a hand-staged one,
# carries. The callee wrote its transcript under the REALPATH encoding, as Claude Code
# always does.
stage_herdr_dir "$cd_path" hotline-r-link "herdr-sess" "$NONCE" "$LINKED_CWD"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "the symlinked answer"
[[ ! -f "$t/home/.claude/projects/$(encode_cwd "$LINKED_CWD")/herdr-sess.jsonl" ]]
check "the fixture really has NO transcript under the literal cwd spelling (guards the guard)" $? \
  "literal-spelling path exists, so this case would pass without the fix"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"the symlinked answer"* ]]
check "a symlinked cwd.txt still finds the REALPATH-encoded transcript (live-caught blocker)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# And the launcher's half of the same fix: cwd.txt is canonicalized at write time, so
# the two spellings normally coincide by construction rather than by search.
t=$(new_env)
ln -s "$t/target" "$t/linked"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_PANE_ID="w1:p1" \
      bash "$HERDR_ASYNC" --cwd "$t/linked" --prompt "hi" 2>"$t/err.txt")
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ "$(cat "$cd_path/cwd.txt" 2>/dev/null)" == "$(cd "$t/target" && pwd -P)" ]]
check "the launcher canonicalizes cwd.txt, so every consumer derives the encoding the callee uses" $? \
  "cwd.txt='$(cat "$cd_path/cwd.txt" 2>/dev/null)' want='$(cd "$t/target" && pwd -P)'"
grep -q -- "--cwd $(cd "$t/target" && pwd -P) " <(tr -d '\\' < "$t/herdr.log")
check "…and splits the pane in that same canonical cwd, so the callee resolves there" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
NONCE="1122334455667788"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-2 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=working \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 6 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'Timed out' "$cd_path/error.txt"
check "WORK_IN_PROGRESS keeps waiting, then times out (never a false completion)" $? \
  "rc=$rc out=$out error=$(cat "$cd_path/error.txt" 2>/dev/null)"
grep -q 'agent wait hotline-r-2 --until idle --until done --until blocked' \
  <(tr -d '\\' < "$t/herdr.log")
check "…gating on the settled SET (idle+done+blocked), never on idle alone" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ -s "$cd_path/waiter_timeout.txt" ]]
check "…and marks the budget resumable, so re-running gets a fresh one" $? \
  "call_dir: $(ls "$cd_path" | tr '\n' ' ')"

t=$(new_env)
NONCE="aaaabbbbccccdddd"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-3 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" AWAITING_REVIEW "step 1 of 3 done"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 4 && "$(jq -r '.awaiting_review' <<<"$out" 2>/dev/null)" == "true" ]]
check "AWAITING_REVIEW → exit 4 with the same additive marker as cmux" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

t=$(new_env)
NONCE="9999888877776666"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-4 "herdr-sess" "$NONCE" "$t/target"
TR="$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl"
transcript_with "$TR" "$NONCE" "" "on it"
printf '{"type":"user","sessionId":"herdr-sess","message":{"content":"actually do the migration instead"}}\n' >> "$TR"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 3 ]] && grep -q 'reassigned mid-call' "$t/err.txt"
check "a preempted callee → exit 3, naming the preempting prompt" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# A call dir with no agent name is still a launcher bug — but the ANSWER may already
# be on disk, and refusing to look because the GATE is missing throws away a finished
# work order. So the transcript is read first, and the loud refusal happens only at
# the point of actually needing the gate.
t=$(new_env)
NONCE="d0d0d0d0e1e1e1e1"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-noagent "herdr-sess" "$NONCE" "$t/target"
rm -f "$cd_path/herdr_agent.txt"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "answered before the handle went missing"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 10 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"answered before the handle went missing"* ]]
check "no agent name but an answer on disk → the answer, not a launcher-bug error" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# …and with nothing on disk to salvage, it still fails loudly rather than degrading
# into a bare file poll that would sit out the whole budget.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-noagent2 "herdr-sess" "n-na2" "$t/target"
rm -f "$cd_path/herdr_agent.txt"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "n-na2" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'no herdr_agent.txt' "$t/err.txt" && grep -q 'launcher bug' "$t/err.txt"
check "…and with no answer on disk it still fails loudly as a launcher bug" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-5 "herdr-sess" "n5" "$t/target"
rm -f "$cd_path/cwd.txt"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 5 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'no screen fallback' "$t/err.txt" \
  && grep -q 'cwd.txt=MISSING' "$t/err.txt"
check "no derivable transcript → a hard stop that names the MISSING input" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…decided before any herdr call (there is no weaker tier to try)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
NONCE="5555444433332222"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-6 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "started, then died"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_GONE=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -ne 0 ]] && grep -q 'exited before answering' "$t/err.txt"
check "an agent that vanished mid-call fails FAST instead of sitting out the budget" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-r-7 "herdr-sess" "n7" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HOTLINE_POLL_SLEEP=0 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 30 2>"$t/err.txt"); rc=$?
# The message names EVERY derived candidate, not one path: naming a single path is
# how it once asserted "the prompt never reached the agent" about a callee whose
# finished answer was in the other spelling.
[[ $rc -ne 0 ]] && grep -q 'No transcript after' "$t/err.txt" \
  && grep -q 'at any derived path' "$t/err.txt"
check "a transcript that never appears is reported as 'the prompt never landed', naming every candidate" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# ===========================================================================
echo ""
echo "5. dial.sh selection and refusals:"
# ===========================================================================

dial() {  # dial <scratch> <extra-env...> -- <dial args...>
  local t="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" \
      HOTLINE_CALLER_SESSION_ID="caller-dial-1" \
      HOTLINE_PENDING_DIR="$t/pending" \
      ${envs[@]+"${envs[@]}"} bash "$DIAL" "$@" 2>"$t/err.txt"
}

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--transport herdr --detached"* ]]
check "--transport herdr with the DEFAULT side placement is refused, with the fix in the recovery" $? \
  "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --window lindris)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"detached only"* ]]
check "--transport herdr --window is refused (herdr has no in-your-window placement)" $? \
  "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode conference --prompt "hi" \
        --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"conference"* ]]
check "--transport herdr --mode conference is refused, pointing at attach (Phase 3)" $? "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --detached --remote box.local)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"Phase 3"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"transcript"* ]]
check "--transport herdr --remote is refused, and the reason is the REMOTE TRANSCRIPT" $? "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" --remote box.local)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"not supported by any hotline transport"* ]]
check "--remote alone is refused too (no backend hosts remotely yet)" $? "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --detached --resume some-session)
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"--resume"* ]]
check "--transport herdr --resume is refused (Phase 2)" $? "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" --transport nope)
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"Unknown --transport"* ]]
check "an unknown --transport is refused with the valid list" $? "out=$out"

# Two explicit, incompatible backends. Silently honouring either would discard a
# flag the caller typed on purpose.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --detached --headless)
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"ask for different backends"* ]]
check "--headless together with --transport herdr is refused, not silently resolved" $? "out=$out"

# A failed herdr preflight is an ERROR. Not cmux (the caller wanted persistence),
# not headless (no live host to follow up into) — and the reason is preflight's own.
t=$(new_env)
out=$(dial "$t" HERDR_STUB_SESSION_RC=1 -- --target "$t/target" --mode work_order \
        --prompt "hi" --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"no server answered"* ]]
check "a failed herdr preflight is an ERROR at stage=transport, carrying preflight's reason" $? \
  "out=$out"
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]] \
  && ! grep -q 'new-workspace' "$t/cmux.log" 2>/dev/null
check "…and it NEVER silently degrades to cmux or headless" $? \
  "out=$out cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# herdr is available AND the caller is sitting inside a herdr pane — and it is still
# not selected. Auto-detect must only ENABLE the option, never pick it: flipping the
# default on an ambient signal would surprise every interactive local caller.
t=$(new_env)
cat > "$t/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","session_id":"headless-sess"}\n'
printf '{"type":"result","session_id":"headless-sess","result":"ok","num_turns":1}\n'
EOF
chmod +x "$t/bin/claude"
out=$(dial "$t" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]]
check "HERDR_ENV=1 never SELECTS herdr — the default stays cmux's chain" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…and no herdr preflight is even run without the explicit flag" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# A cached session for this target means this is a FOLLOW-UP, which herdr Phase 1
# cannot host. Refused rather than silently starting a context-free fresh callee.
t=$(new_env)
mkdir -p "$t/home/.agents-hotline/sessions"
jq -nc --arg t "$(cd "$t/target" && pwd -P)" \
  '{caller_session_id:"caller-dial-1",
    connections:{($t):{session_id:"prior-session-1",mode:"work_order",
                       exchange_count:1,last_call_id:"prior-nonce"}}}' \
  > "$t/home/.agents-hotline/sessions/caller-dial-1.json"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "and now step 2" --transport herdr --detached)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"first-contact only"* ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"prior-session-1"* ]]
check "a herdr dial into an already-cached session is refused (Phase 2), naming the session" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
# The preflight's read-only probes may have run (selection precedes the cache
# lookup); what must NOT have happened is placing a host for a session that is
# already live somewhere.
! grep -qE 'pane split|agent start' "$t/herdr.log" 2>/dev/null
check "…before placing any host, so no second host is created for a live session" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --transport headless is just another way to say --headless.
t=$(new_env)
cat > "$t/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","session_id":"headless-sess"}\n'
printf '{"type":"result","session_id":"headless-sess","result":"ok","num_turns":1}\n'
EOF
chmod +x "$t/bin/claude"
out=$(dial "$t" -- --target "$t/target" --mode quick --prompt "hi" --transport headless)
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "headless" ]]
check "--transport headless routes exactly where --headless does" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…and never touches herdr" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- end to end through dial.sh: the callee never records the prompt ---------
# The plain stub submits without the callee writing anything, which is exactly the
# shape of a delivery that cannot be confirmed. That must be an ERROR: the agent is
# live and was told nothing we can prove, so "connected" would leave the caller
# waiting on a response to a message that may not exist.
t=$(new_env)
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" ]]
check "an unconfirmable herdr delivery errors at stage=deliver, never reports connected" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" && "$(cat "$call_dir/transport.txt" 2>/dev/null)" == "herdr" \
   && -s "$call_dir/herdr_agent.txt" && -s "$call_dir/pending_paste.md" ]]
check "…leaving the payload in pending_paste.md for recovery, as the cmux path does" $? \
  "call_dir: $(ls "$call_dir" 2>/dev/null | tr '\n' ' ')"
grep -q 'agent start' <(tr -d '\\' < "$t/herdr.log")
check "…having really run launch → boot → deliver in order" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ ! -s "$t/cmux.log" ]]
check "…and made no cmux call: an explicit herdr dial never consults cmux" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# --- end to end through dial.sh: the callee DOES record it -------------------
# The plain stub cannot precompute the transcript path (it does not know the session
# id until `agent start` hands it one), so a thin wrapper fills that in — modelling
# the callee writing the prompt it received to its own transcript, which is the tier
# a live delivery is confirmed by.
t=$(new_env)
# The REALPATH spelling of the cwd, deliberately: dial.sh resolves its target
# through resolve-workspace.sh, and a callee under /tmp on macOS actually writes to
# the /private/tmp encoding. Confirmation checks both spellings of whatever cwd it
# is given, so writing the realpath one is correct either way.
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]]
check "a confirmed herdr delivery reports status=connected" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "detached" ]]
check "…with transport=herdr and placement=detached" $? "out=$out"
[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == hotline-* ]]
check "…and the herdr AGENT NAME in the stable host-ref field (.surface_ref)" $? "out=$out"
[[ -n "$(jq -r '.remote_session_id // empty' <<<"$out" 2>/dev/null)" \
   && -n "$(jq -r '.call_id // empty' <<<"$out" 2>/dev/null)" ]]
check "…and the contract's .remote_session_id / .call_id unchanged in shape" $? "out=$out"
call_dir=$(jq -r '.call_dir' <<<"$out" 2>/dev/null)
[[ ! -f "$call_dir/pending_paste.md" ]]
check "…and the delivered payload is removed (the transcript is the record now)" $? \
  "call_dir: $(ls "$call_dir" 2>/dev/null | tr '\n' ' ')"
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]]
check "…with no fallbacks: the session id herdr observed matched the one we preset" $? "out=$out"

# --- a preset/observed session-id disagreement reaches the emitted JSON ------
# It is the single most diagnostic signal when a herdr dial later goes quiet, and a
# fact recorded only in a temp dir is a fact nobody reads. The call still SUCCEEDS —
# the launcher adopts herdr's observed id, which is the correct one — so this is a
# fallback note rather than an error.
t=$(new_env)
OBS_SID="eeeeeeee-2222-4222-8222-333333333333"
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$OBS_SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_OBSERVED_SID=$OBS_SID" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.remote_session_id' <<<"$out" 2>/dev/null)" == "$OBS_SID" ]]
check "an observed session id different from the preset still connects, on the OBSERVED id" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"herdr-session-id-mismatch(preset="* ]]
check "…and the disagreement is reported in .fallbacks, not just left in the call dir" $? "out=$out"

# ===========================================================================
echo ""
echo "6. Doc canaries — a stated default has one source:"
# ===========================================================================
# SKILL.md states these numbers, and the scripts define them. Two copies of a
# constant is how a documented "default 60" sat next to a hardcoded 20 at both call
# sites, so each restatement gets a canary rather than trust.
DIAL_SKILL="$HOTLINE_DIR/skills/dial/SKILL.md"
# Flattened: the doc wraps its bullets, so the variable and its stated default are
# on different LINES. A line-oriented grep would silently never match and the canary
# would assert nothing.
SKILL_FLAT=$(tr '\n' ' ' < "$DIAL_SKILL" | tr -s ' ')

[[ "$SKILL_FLAT" == *'HOTLINE_HERDR_SPLIT_DIRECTION=right|down`** — which way that split goes (default `right`)'* ]] \
  && grep -q 'HOTLINE_HERDR_SPLIT_DIRECTION:-right' "$HERDR_ASYNC"
check "SKILL.md's split-direction default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_SPLIT_DIRECTION:-[a-z]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'freshly split pane (default 1)'* ]] \
  && grep -q 'HOTLINE_HERDR_PANE_SETTLE:-1}' "$HERDR_ASYNC"
check "SKILL.md's pane-settle default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_PANE_SETTLE:-[0-9]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'re-reads the transcript (default 30000)'* ]] \
  && grep -q 'HOTLINE_HERDR_WAIT_SLICE_MS:-30000}' "$WAIT_RESPONSE"
check "SKILL.md's wait-slice default matches wait-for-response.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_WAIT_SLICE_MS:-[0-9]*' "$WAIT_RESPONSE")"

# A herdr error hint must point at the section that actually covers herdr, not at
# the cmux one — an error hint naming the wrong section is worse than none.
grep -q '## herdr Failures' "$HOTLINE_DIR/skills/dial/references/error-recovery.md"
check "error-recovery.md has the § herdr Failures section the hints name" $? \
  "sections: $(grep -c '^## ' "$HOTLINE_DIR/skills/dial/references/error-recovery.md")"

# ---------------------------------------------------------------------------
echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ -s "$POISON_LOG" ]]; then
  echo ""
  echo "TEST BUG: a case reached a real binary (missing PATH stub):"
  cat "$POISON_LOG"
  exit 1
fi
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
