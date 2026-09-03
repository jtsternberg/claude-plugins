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
export HOTLINE_HERDR_FIRST_SETTLE=0
export HOTLINE_HERDR_READY_TRIES=2
export HOTLINE_HERDR_FIRST_CONFIRM_TRIES=2
export HOTLINE_HERDR_BLOCKED_SETTLE=0
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
#   HERDR_STUB_GONE_NAMES     space-separated names `agent get` answers
#                             agent_not_found for, while every OTHER name still
#                             resolves — the follow-up shape where the CACHED agent
#                             has exited and a freshly started one has not
#   HERDR_STUB_AGENT_ANY=1    `agent get` resolves any name (for waiter cases whose
#                             agent was never "started" through this stub)
#   HERDR_STUB_STATUS         the agent_status `agent get` reports (default idle)
#   HERDR_STUB_GET_READY      the interactive_ready `agent get` reports (default
#                             true). 'omit' drops the field entirely — the herdr
#                             that stops reporting it must not make delivery
#                             impossible, only unproven
#   HERDR_STUB_READY_AFTER=N  `agent get` reports interactive_ready:false for its
#                             first N calls and true after — the readiness RACE,
#                             which is the whole point of the first-contact gate
#   HERDR_STUB_BLOCKED_ONCE=1 `agent get` reports blocked on its FIRST call and
#                             HERDR_STUB_STATUS after — a blocked BLINK, which every
#                             path that ends a call on `blocked` must not act on
#   HERDR_STUB_GONE_AFTER=N   `agent get` resolves for its first N calls and answers
#                             agent_not_found after — an agent that exits BETWEEN
#                             two reads of it
#   HERDR_STUB_WAIT_STATUS    the agent_status `agent wait` settles on (default:
#                             HERDR_STUB_STATUS, else done)
#   HERDR_STUB_SCREEN         file whose contents `agent read` returns as the agent's
#                             screen (default: an idle claude input box)
#   HERDR_STUB_READ_FAIL=1    `agent read` returns a server error
#   HERDR_STUB_AGENT_PANE     the pane_id `agent get` reports (default w1:p9) — what
#                             a split delivery's `pane send-text` half addresses
#   HERDR_STUB_NO_PANE_ID=1   `agent get` omits pane_id entirely
#   HERDR_STUB_SENDTEXT_FAIL=1 `pane send-text` returns a server error
#   HERDR_STUB_PROMPT_FAIL=1  `agent prompt` returns a server error
#   HERDR_STUB_TRANSCRIPT     `agent prompt` appends a realistic user record to this
#                             .jsonl carrying whatever `pane send-text` had already
#                             placed in the input box PLUS the submitted text — i.e.
#                             the callee recording the turn it actually received. A
#                             split delivery is only confirmable if both halves
#                             arrived, which is the point
#   HERDR_STUB_WAIT_RC        exit code for `agent wait` (default 0)
#   HERDR_STUB_FOCUS_FAIL=1   `agent focus` returns a server error — a conference
#                             whose pane could not be focused is still a live call
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
    for _gone in ${HERDR_STUB_GONE_NAMES:-}; do
      [[ "$NAME" == "$_gone" ]] && err agent_not_found "agent target $NAME not found"
    done
    if [[ -n "${HERDR_STUB_GONE_AFTER:-}" ]]; then
      LIVE=0; [[ -f "$ST/lives" ]] && LIVE=$(cat "$ST/lives")
      LIVE=$((LIVE + 1)); echo "$LIVE" > "$ST/lives"
      [[ "$LIVE" -gt "$HERDR_STUB_GONE_AFTER" ]] \
        && err agent_not_found "agent target $NAME not found"
    fi
    if [[ "${HERDR_STUB_AGENT_ANY:-}" != "1" ]]; then
      grep -qxF "$NAME" "$ST/started" 2>/dev/null \
        || err agent_not_found "agent target $NAME not found"
    fi
    SID="${HERDR_STUB_OBSERVED_SID:-$(cat "$ST/session_id" 2>/dev/null || true)}"
    READY="${HERDR_STUB_GET_READY:-true}"
    STATUS="${HERDR_STUB_STATUS:-idle}"
    # A blocked BLINK: blocked once, then whatever the case asked for.
    if [[ "${HERDR_STUB_BLOCKED_ONCE:-}" == "1" ]]; then
      if [[ -f "$ST/blinked" ]]; then :; else STATUS=blocked; printf 1 > "$ST/blinked"; fi
    fi
    # The readiness race: false until the Nth read, true after. Counted in the
    # stub's own state so the count survives across the gate's separate calls.
    if [[ -n "${HERDR_STUB_READY_AFTER:-}" ]]; then
      GETS=0; [[ -f "$ST/gets" ]] && GETS=$(cat "$ST/gets")
      GETS=$((GETS + 1)); echo "$GETS" > "$ST/gets"
      if [[ "$GETS" -le "$HERDR_STUB_READY_AFTER" ]]; then READY=false; else READY=true; fi
    fi
    PANE="${HERDR_STUB_AGENT_PANE:-w1:p9}"
    [[ "${HERDR_STUB_NO_PANE_ID:-}" == "1" ]] && PANE=""
    jq -nc --arg n "$NAME" --arg s "$STATUS" --arg sid "$SID" \
           --arg ready "$READY" --arg pane "$PANE" \
      '{id:"cli:agent:get",result:{agent:({name:$n,agent:"claude",agent_status:$s,
         agent_session:{agent:"claude",kind:"id",source:"herdr:claude",value:$sid}}
         + (if $ready == "omit" then {} else {interactive_ready:($ready == "true")} end)
         + (if $pane == "" then {} else {pane_id:$pane} end))}}'
    exit 0 ;;

  "agent read")
    # PLAIN TEXT, not JSON — the real CLI prints the rendered screen.
    [[ "${HERDR_STUB_READ_FAIL:-}" == "1" ]] && err agent_read_failed "no such agent"
    if [[ -n "${HERDR_STUB_SCREEN:-}" ]]; then cat "$HERDR_STUB_SCREEN"; else printf '\xe2\x9d\xaf\xc2\xa0\n'; fi
    exit 0 ;;

  "pane send-text")
    # The callee's INPUT BOX, modelled: literal text with no Enter, so it
    # accumulates until an `agent prompt` submits the whole buffer.
    [[ "${HERDR_STUB_SENDTEXT_FAIL:-}" == "1" ]] && err pane_send_text_failed "no such pane"
    printf '%s' "$4" >> "$ST/box"
    echo '{"id":"cli:pane:send-text","result":{"sent":true}}'
    exit 0 ;;

  "agent prompt")
    [[ "${HERDR_STUB_PROMPT_FAIL:-}" == "1" ]] && err agent_prompt_failed "no such agent"
    if [[ -n "${HERDR_STUB_TRANSCRIPT:-}" ]]; then
      mkdir -p "$(dirname "$HERDR_STUB_TRANSCRIPT")"
      jq -nc --arg t "$(cat "$ST/box" 2>/dev/null || true)$4" \
             --arg sid "$(cat "$ST/session_id" 2>/dev/null || echo stub-session)" \
        '{type:"user",isSidechain:false,sessionId:$sid,message:{content:$t}}' \
        >> "$HERDR_STUB_TRANSCRIPT"
    fi
    rm -f "$ST/box"
    echo '{"id":"cli:agent:prompt","result":{"submitted":true}}'
    exit 0 ;;

  "agent focus")
    # The ONE call that moves the user's focus, and only a conference makes it.
    [[ "${HERDR_STUB_FOCUS_FAIL:-}" == "1" ]] && err agent_focus_failed "agent target $3 not found"
    echo '{"id":"cli:agent:focus","result":{"focused":true}}'
    exit 0 ;;

  "agent wait")
    jq -nc --arg s "${HERDR_STUB_WAIT_STATUS:-${HERDR_STUB_STATUS:-done}}" \
      '{id:"cli:agent:wait",result:{agent:{agent_status:$s}}}'
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

# Wrap the stub so `agent prompt` records the payload in the callee's transcript —
# the tier a delivery is confirmed by. The session id is whatever `agent start`
# last reported, falling back to the id passed here (a reuse launches nothing, so
# the stub's state file does not exist).
wrap_herdr_transcript() {  # wrap_herdr_transcript <scratch> <fallback-session-id>
  local t="$1" fallback="$2"
  mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
  cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo "$fallback")
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
  chmod +x "$t/bin/herdr"
}

# A `claude -p` stub, for the cases whose dial is expected to land on headless.
stub_headless_claude() {  # <scratch>
  cat > "$1/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"system","session_id":"headless-sess"}\n'
printf '{"type":"result","session_id":"headless-sess","result":"ok","num_turns":1}\n'
EOF
  chmod +x "$1/bin/claude"
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

# --- A slash command with a body is delivered in TWO writes (claude-plugins-fvhx) --
# One atomic `agent prompt` collapses the multi-line paste, the invocation stops being
# the literal start of the input, and the callee reads the work order as plain text:
# no ringing protocol, no STATUS, no call_id, and transcript-extract.sh exits 10
# forever. The nonce below lives in the INVOCATION LINE only, so a confirmed delivery
# proves both writes reached the same input box.

t=$(new_env)
SID="herdr-split-1"
NONCE="ee55ff66aa77bb88"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
{ printf '/hotline:hotline-ringing [CALL_ID: %s] [MODE: work_order]\n' "$NONCE"
  printf 'line one of the work order\nline two\nline three\nline four\n'; } > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_AGENT_PANE="w1:p7" \
      bash "$HERDR_PROMPT" --agent hotline-s-1 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "a slash-command payload with a body is delivered and confirmed" $? "out=$out"
log=$(tr -d '\\' < "$t/herdr.log")
grep -q 'pane send-text w1:p7 /hotline:hotline-ringing' <<<"$log"
check "…the INVOCATION LINE goes out alone via pane send-text (no Enter, no submit)" $? \
  "herdr calls: $log"
# Both line numbers are required to EXIST: bash reads an empty string as 0 in an
# arithmetic comparison, so "no send-text call at all" would otherwise satisfy
# "send-text came first" — the exact failure this case exists to catch.
SENDTEXT_LINE=$(grep -n 'pane send-text' <<<"$log" | head -1 | cut -d: -f1)
PROMPT_LINE=$(grep -n 'agent prompt' <<<"$log" | head -1 | cut -d: -f1)
[[ -n "$SENDTEXT_LINE" && -n "$PROMPT_LINE" && "$SENDTEXT_LINE" -lt "$PROMPT_LINE" ]]
check "…before the body's submit, never after" $? \
  "send-text=$SENDTEXT_LINE prompt=$PROMPT_LINE herdr calls: $log"
! grep 'agent prompt' <<<"$log" | grep -q '/hotline:hotline-ringing'
check "…and the submitted half carries the BODY only (the head is already in the box)" $? \
  "herdr calls: $log"
grep -q "$NONCE" "$TRANS" 2>/dev/null && grep -q 'line four' "$TRANS" 2>/dev/null
check "…so the callee's turn holds head AND body, byte-for-byte one payload" $? \
  "transcript: $(cat "$TRANS" 2>/dev/null)"

# A ONE-LINE slash command needs no split: nothing collapses, and a second write
# would only add a round trip.
t=$(new_env)
SID="herdr-split-2"
NONCE="ff66aa77bb88cc99"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '/hotline:hotline-ringing [CALL_ID: %s] status?' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-s-2 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]] \
  && ! grep -q 'pane send-text' "$t/herdr.log" 2>/dev/null
check "a single-line slash command takes the one-write path unchanged" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# A MULTI-LINE payload that is not a slash command needs no split either: there is no
# invocation for a placeholder to swallow.
t=$(new_env)
SID="herdr-split-3"
NONCE="aa77bb88cc99dd00"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nfollow-up question\nsecond line\nthird line\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-s-3 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]] \
  && ! grep -q 'pane send-text' "$t/herdr.log" 2>/dev/null
check "a multi-line payload with no slash command takes the one-write path" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The PREDICATE decides, not the --first-contact flag: a follow-up that happens to be
# a slash command with a body would lose its invocation exactly the same way.
t=$(new_env)
SID="herdr-split-4"
NONCE="bb88cc99dd00ee11"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
{ printf '/hotline:hotline-ringing [CALL_ID: %s]\n' "$NONCE"; printf 'body\nmore body\n'; } > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-s-4 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]] \
  && grep -q 'pane send-text' <(tr -d '\\' < "$t/herdr.log")
check "a FOLLOW-UP slash command with a body splits too (the predicate decides)" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The first write failing is pre-submit: nothing is in the box, nothing was submitted.
t=$(new_env)
{ printf '/hotline:hotline-ringing [CALL_ID: n]\n'; printf 'body\nmore\n'; } > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SENDTEXT_FAIL=1 \
      bash "$HERDR_PROMPT" --agent hotline-s-5 --payload-file "$t/payload.md" \
        --call-id n --cwd "$t/target" --session s-s5 --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a failed invocation-line write → delivered:false sent:FALSE (re-dial is safe)" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and the body is never submitted on its own" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# No pane to write the invocation line into → REFUSE. Delivering unsplit instead would
# be a false success: the nonce would reach the transcript, delivery would report
# confirmed, and the caller would wait forever for a protocol that never engaged.
t=$(new_env)
SID="herdr-split-6"
NONCE="cc99dd00ee11ff22"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
{ printf '/hotline:hotline-ringing [CALL_ID: %s]\n' "$NONCE"; printf 'body\nmore\n'; } > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_NO_PANE_ID=1 \
      bash "$HERDR_PROMPT" --agent hotline-s-6 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no pane_id"* ]]
check "an agent with no pane_id → refused sent:false rather than delivered unsplit" $? "out=$out"
! grep -qE 'agent prompt|pane send-text' "$t/herdr.log" 2>/dev/null
check "…with nothing written into the callee at all" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# --- First contact is gated harder than a follow-up (claude-plugins-7wze.12) --
# The opening payload is the one delivery that can lose the whole work order, and it
# did, live, under load. Everything below is PRE-SUBMIT: the gate refuses with
# sent:false, so a caller may re-dial without risking a double-run.

# The readiness RACE, which is the whole reason the gate exists: `agent start`
# claimed the REPL was ready, the first re-probe disagrees, the next one agrees.
t=$(new_env)
SID="herdr-first-1"
NONCE="cc11dd22ee33ff44"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nthe work order\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_READY_AFTER=1 \
      bash "$HERDR_PROMPT" --agent hotline-f-1 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "first contact waits out an interactive_ready:false blink and then delivers" $? "out=$out"
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$(grep -c 'agent get hotline-f-1' <<<"$log")" -ge 2 ]] \
  && [[ "$(grep -n 'agent prompt' <<<"$log" | head -1 | cut -d: -f1)" -gt \
        "$(grep -n 'agent get' <<<"$log" | tail -1 | cut -d: -f1)" ]]
check "…re-probing until it agrees, and submitting only AFTER the last probe" $? \
  "herdr calls: $log"

# Never ready → refused, and refused sent:false. `agent start`'s claim is not a
# submit-time fact, and a payload into whatever IS there would be lost silently.
t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_GET_READY=false \
      bash "$HERDR_PROMPT" --agent hotline-f-2 --payload-file "$t/payload.md" \
        --call-id nonce-f2 --cwd "$t/target" --session s-f2 --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"never reported interactive_ready"* ]]
check "an agent that never becomes interactive-ready → refused, sent:FALSE (re-dial is safe)" $? \
  "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…with nothing submitted at all" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# BLOCKED before first contact: the likelier half of the live failure. A startup
# trust prompt IS interactive — the dialog takes keystrokes — so submitting there
# answers the gate and the work order never becomes a turn.
t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      bash "$HERDR_PROMPT" --agent hotline-f-3 --payload-file "$t/payload.md" \
        --call-id nonce-f3 --cwd "$t/target" --session s-f3 --first-contact 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"blocked"* ]]
check "a callee BLOCKED before first contact → refused sent:false, not fed into the gate" $? \
  "out=$out"
[[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"herdr agent attach hotline-f-3"* ]]
check "…naming the attach command that shows what it is asking" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and submitting nothing" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# THE STARTUP TRUST DIALOG (claude-plugins-59ry). herdr reports a callee sitting on it
# as interactive_ready:true and NOT blocked — the dialog really does take keystrokes —
# so the readiness gate above passes it and the payload answers the dialog's default
# option, `No, exit`. Live-confirmed on CC 2.1.251 / herdr 0.8.0 in a fresh `git init`
# directory. Only a screen read catches this.
trust_dialog_screen() {  # <file> <cwd>
  cat > "$1" <<TRUST
 Accessing workspace:

 $2

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
TRUST
}

# The SAME dialog as a narrow herdr pane renders it. Live-caught on a ~16-column pane
# (five panes in one workspace): the paragraph and BOTH option lines reflow, so no raw
# substring of the wording survives and the pre-normalization predicate waved the
# payload through into the dialog.
trust_dialog_screen_wrapped() {  # <file> <cwd>
  cat > "$1" <<TRUSTW
 Accessing
 workspace:

 $2

 Quick safety
 check: Is this a
 project you
 created or one
 you trust?

 Security guide

 ❯ No, exit
   Yes, I trust
   this folder

 Enter to
 confirm · Esc
 to cancel
TRUSTW
}

t=$(new_env)
trust_dialog_screen "$t/screen.txt" "$t/target"
printf '/hotline:hotline-ringing [CALL_ID: n-t1]\nthe work order\nmore of it\n' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SCREEN="$t/screen.txt" \
      bash "$HERDR_PROMPT" --agent hotline-t-1 --payload-file "$t/payload.md" \
        --call-id n-t1 --cwd "$t/target" --session s-t1 --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a callee on the startup TRUST DIALOG → refused sent:FALSE, though herdr calls it ready" $? \
  "out=$out"
reason=$(jq -r '.reason' <<<"$out" 2>/dev/null)
[[ "$reason" == *"TRUST DIALOG"* && "$reason" == *"$t/target"* ]]
check "…naming the dialog and the cwd Claude Code has not trusted" $? "reason=$reason"
[[ "$reason" == *"No, exit"* && "$reason" == *"herdr agent attach hotline-t-1"* \
   && "$reason" == *"HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS does not cover"* ]]
check "…what a submit would have answered, how to look, and that the skip flag is no fix" $? \
  "reason=$reason"
# dial.sh forwards this through reason_of, which truncates at 300 chars — so the FIX
# has to be inside that window or the caller never reads it (live-caught: the first
# wording put the diagnosis first and lost every instruction).
[[ "${reason:0:300}" == *"$t/target"* && "${reason:0:300}" == *"trust that directory"* \
   && "${reason:0:300}" == *"re-dial"* ]]
check "…with the cwd and the remedy inside reason_of's first 300 characters" $? \
  "first 300: ${reason:0:300}"
! grep -qE 'agent prompt|pane send-text' "$t/herdr.log" 2>/dev/null
check "…and writing nothing into the dialog" $? "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The read is PRE-SUBMIT, which is the only place it can help.
t=$(new_env)
SID="herdr-trust-2"
NONCE="dd00ee11ff22aa33"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      bash "$HERDR_PROMPT" --agent hotline-t-2 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "an ordinary REPL screen is no obstacle: first contact still delivers" $? "out=$out"
log=$(tr -d '\\' < "$t/herdr.log")
READ_LINE=$(grep -n 'agent read' <<<"$log" | head -1 | cut -d: -f1)
SUBMIT_LINE=$(grep -n 'agent prompt' <<<"$log" | head -1 | cut -d: -f1)
[[ -n "$READ_LINE" && -n "$SUBMIT_LINE" && "$READ_LINE" -lt "$SUBMIT_LINE" ]]
check "…having read the screen BEFORE submitting anything" $? \
  "read=$READ_LINE submit=$SUBMIT_LINE herdr calls: $log"

# An unreadable screen is permission to proceed, not a refusal — the probe can prove a
# dialog is there, never that one is not, and a herdr whose `agent read` changes shape
# must not make delivery impossible.
t=$(new_env)
SID="herdr-trust-3"
NONCE="ee11ff22aa33bb44"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_READ_FAIL=1 \
      bash "$HERDR_PROMPT" --agent hotline-t-3 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "a screen that cannot be read proceeds (unproven, not impossible)" $? "out=$out"

# FIRST CONTACT ONLY, like the readiness gate beside it: a follow-up's agent has
# already taken a prompt and answered one, which no startup dialog survives.
t=$(new_env)
trust_dialog_screen "$t/screen.txt" "$t/target"
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SCREEN="$t/screen.txt" \
      bash "$HERDR_PROMPT" --agent hotline-t-4 --payload-file "$t/payload.md" \
        --call-id n-t4 --cwd "$t/target" --session s-t4 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]] \
  && ! grep -q 'agent read' "$t/herdr.log" 2>/dev/null
check "without --first-contact no screen is read at all (the gate is the opening one)" $? \
  "out=$out herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# THE NARROW PANE, end to end. Same dialog, reflowed by a ~16-column pane, and it must
# refuse exactly the same way — this is the live-caught case the predicate's whitespace
# normalization exists for.
t=$(new_env)
trust_dialog_screen_wrapped "$t/screen.txt" "$t/target"
printf '/hotline:hotline-ringing [CALL_ID: n-t5]\nthe work order\nmore of it\n' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_SCREEN="$t/screen.txt" \
      bash "$HERDR_PROMPT" --agent hotline-t-5 --payload-file "$t/payload.md" \
        --call-id n-t5 --cwd "$t/target" --session s-t5 --first-contact 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"TRUST DIALOG"* ]]
check "a NARROW pane's wrapped trust dialog is refused too (no raw substring survives it)" $? \
  "out=$out"
! grep -qE 'agent prompt|pane send-text' "$t/herdr.log" 2>/dev/null
check "…writing nothing into it either" $? "herdr calls: $(tr -d '\\' < "$t/herdr.log")"
# The fixture has to be genuinely wrapped, or the case above proves nothing.
! grep -qF 'I trust this folder' "$t/screen.txt" && ! grep -qF 'Quick safety check' "$t/screen.txt"
check "…and the fixture really does break every wording across lines" $? \
  "screen: $(cat "$t/screen.txt")"
# `--source recent`, not `visible`: a narrow pane's VIEWPORT clips the top of a wrapped
# dialog, so the wording can be off-screen entirely (measured live at ~16 columns).
grep -q 'agent read hotline-t-5 --source recent' <(tr -d '\\' < "$t/herdr.log")
check "…read from --source recent, which carries the whole dialog at any width" $? \
  "herdr calls: $(tr -d '\\' < "$t/herdr.log")"

# The predicate itself: the older wording of the same dialog must still fire, because a
# false negative kills the callee while a false positive only costs a refusal.
source "$HOTLINE_DIR/scripts/repl-state.sh"
# Its own full-width fixture: $t/screen.txt belongs to the case above, and reading that
# one here would quietly test the WRAPPED text under the unwrapped label.
trust_dialog_screen "$t/fullwidth.txt" /private/tmp/x
repl_trust_dialog_present "$(cat "$t/fullwidth.txt")" \
  && pass "trust dialog: the shipped CC 2.1.251 wording" \
  || fail "trust dialog: the shipped CC 2.1.251 wording"
repl_trust_dialog_present ' Do you trust the files in this folder?
 ❯ 1. Yes, proceed
   2. No, exit' \
  && pass "trust dialog: the older 'Do you trust the files in this folder?' wording" \
  || fail "trust dialog: the older 'Do you trust the files in this folder?' wording"
! repl_trust_dialog_present "$(printf '\xe2\x9d\xaf\xc2\xa0\n  what would you like me to do?\n')" \
  && pass "trust dialog: an ordinary idle REPL is not one" \
  || fail "trust dialog: an ordinary idle REPL is not one"
! repl_trust_dialog_present "" \
  && pass "trust dialog: an empty capture is not one" \
  || fail "trust dialog: an empty capture is not one"
trust_dialog_screen_wrapped "$t/wrapped.txt" /private/tmp/x
repl_trust_dialog_present "$(cat "$t/wrapped.txt")" \
  && pass "trust dialog: the wording reflowed across lines by a narrow pane" \
  || fail "trust dialog: the wording reflowed across lines by a narrow pane"

# An ABSENT interactive_ready must not make delivery impossible — only unproven. A
# herdr that stops reporting the field would otherwise block every first contact.
t=$(new_env)
SID="herdr-first-4"
NONCE="dd44ee55ff66aa77"
TRANS="$t/home/.claude/projects/$(encode_cwd "$t/target")/$SID.jsonl"
printf '[CALL_ID: %s]\nwork\n' "$NONCE" > "$t/payload.md"
printf '%s' "$SID" > "$t/state/session_id"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_TRANSCRIPT="$TRANS" \
      HERDR_STUB_GET_READY=omit \
      bash "$HERDR_PROMPT" --agent hotline-f-4 --payload-file "$t/payload.md" \
        --call-id "$NONCE" --cwd "$t/target" --session "$SID" --first-contact 2>/dev/null)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" ]]
check "an absent interactive_ready is permission to proceed, not a refusal" $? "out=$out"

# The gate is FIRST CONTACT ONLY. A follow-up's agent has already taken a prompt and
# answered one, which outranks any probe — and its refusals belong to the reuse
# script, where the caller can still fall back.
t=$(new_env)
printf 'x' > "$t/payload.md"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_GET_READY=false \
      bash "$HERDR_PROMPT" --agent hotline-f-5 --payload-file "$t/payload.md" \
        --call-id nonce-f5 --cwd "$t/target" --session s-f5 2>/dev/null)
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]]
check "without --first-contact the readiness gate is skipped (a follow-up is already proven)" $? \
  "out=$out"

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

# SIDE IS ACCEPTED, because it is what herdr already does: every callee is hosted
# in a pane split off the caller's own. The word only changes what `.placement`
# reports — same launch either way (Phase 3a, T2).
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "hi" --transport herdr --placement side --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "side" ]]
check "--transport herdr --placement side CONNECTS, reporting placement=side" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# …and a herdr dial that names NO placement reports SIDE, exactly as the identical
# flagless dial does over cmux. `side` is dial.sh's default placement and it is the
# true one here: the callee is a pane split off the caller's own. There is no
# legacy flagless herdr dial to stay compatible with — before side was accepted, a
# flagless `--transport herdr` was REFUSED (T1).
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "hi" --transport herdr --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "side" ]]
check "…while a herdr dial naming no placement reports side, as cmux does" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# WINDOW IS STILL REFUSED, and the refusal names the missing feature (hotline
# creates no herdr workspaces) rather than a phase — there is no phase pending.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --window lindris)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"side and detached, not window"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--placement side"* ]]
check "--transport herdr --window is refused, naming what herdr does place instead" $? \
  "out=$out"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" != *"session attach"* ]]
check "…and no longer points at \`herdr session attach\` as the answer" $? "out=$out"

# --- conference on herdr: the pane IS the deliverable -----------------------
# Split beside the caller (which is what herdr always does), deliver, then FOCUS —
# the one call in hotline that moves the user. And no response wait: a conference is
# handed to the human, so awaiting_response is false exactly as it is on cmux.
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode conference \
        --prompt "pair with me on this" --transport herdr --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.mode' <<<"$out" 2>/dev/null)" == "conference_call" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" ]]
check "--mode conference --transport herdr CONNECTS instead of being refused" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.awaiting_response' <<<"$out" 2>/dev/null)" == "false" ]]
check "…with awaiting_response FALSE: the session is the user's now, not the caller's" $? \
  "out=$out"
CONF_AGENT=$(jq -r '.surface_ref // empty' <<<"$out" 2>/dev/null)
grep -q "agent focus $CONF_AGENT" <(tr -d '\\' < "$t/herdr.log")
check "…and the callee's pane is FOCUSED, by agent name" $? \
  "agent=$CONF_AGENT herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
# Ordering matters: focusing before the payload is confirmed would put the user in a
# pane while the delivery is still typing into it.
[[ "$(grep -n 'agent focus' <(tr -d '\\' < "$t/herdr.log") | head -1 | cut -d: -f1)" \
   -gt "$(grep -n 'agent prompt' <(tr -d '\\' < "$t/herdr.log") | head -1 | cut -d: -f1)" ]]
check "…focused AFTER the prompt was delivered, never before" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
# The cmux conference path records the surface so a follow-up finds it; the herdr
# path gets the same thing from register-call.sh, and this is what proves it.
[[ "$(jq -r --arg t "$(cd "$t/target" && pwd -P)" '.connections[$t].surface_ref // empty' \
      "$t/home/.agents-hotline/sessions/caller-dial-1.json" 2>/dev/null)" == "$CONF_AGENT" ]]
check "…and the session cache holds the agent, so a conference follow-up re-targets it" $? \
  "cache=$(cat "$t/home/.agents-hotline/sessions/caller-dial-1.json" 2>/dev/null)"

# A WORK ORDER NEVER FOCUSES. Background work that steals the user's cursor lands
# their next keystrokes in a callee's REPL, which is why the split is --no-focus.
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "run the suite" --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]] \
  && ! grep -q 'agent focus' <(tr -d '\\' < "$t/herdr.log")
check "a herdr WORK ORDER never focuses the callee — only a conference does" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(jq -r '.awaiting_response' <<<"$out" 2>/dev/null)" == "true" ]]
check "…and it still awaits a response, unlike the conference" $? "out=$out"

# A focus that fails is a FALLBACK, not an error: the callee is live and holds the
# prompt, so the call succeeded — the user just has to walk to the pane.
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_FOCUS_FAIL=1" \
        -- --target "$t/target" --mode conference --prompt "pair with me" \
           --transport herdr --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]] \
  && [[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"herdr-conference-focus-failed"* ]]
check "a conference whose focus fails still CONNECTS, with the failure in .fallbacks" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

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
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"--resume"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"re-dial the same target"* ]]
check "--transport herdr --resume is refused, pointing at the flagless follow-up instead" $? "out=$out"

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
# not selected. The ambient signal only ENABLES the option; selecting takes an
# opt-in, because flipping the default on the environment alone would surprise
# every interactive local caller.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]]
check "HERDR_ENV=1 alone never SELECTS herdr — the default stays cmux's chain" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…and no herdr preflight is even run without the explicit flag" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# ---------------------------------------------------------------------------
# HOTLINE_TRANSPORT_AUTO — the opt-in that lets the ambient signal decide.
#
# FOUR conditions, all required, and the tests below take one away at a time. The
# point of the guard is that neither half selects alone: the setting is deliberate
# but says nothing about where the caller is, and HERDR_ENV says where they are but
# nobody chose it.
# ---------------------------------------------------------------------------
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 OUTSIDE a herdr pane does not select herdr (no HERDR_ENV, no preflight)" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" ]]
check "AUTO=1 + HERDR_ENV=1 + a usable preflight SELECTS herdr with no --transport" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "side" ]] \
  && [[ ! -s "$t/cmux.log" ]]
check "…reporting side, the placement a flagless dial reports, and never touching cmux" $? \
  "out=$out cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The auto path's failure is a DEGRADE, not an error — the opposite of the explicit
# flag, because nothing was asked for. It must still be visible: a dial that quietly
# lands somewhere else is the thing .fallbacks exists for.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_STUB_NO_PANES=1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]]
check "AUTO=1 with an UNUSABLE herdr degrades to the cmux default instead of erroring" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"transport-auto→cmux("* ]] \
  && [[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"no pane could be resolved"* ]]
check "…recording the degrade in .fallbacks, carrying preflight's own reason" $? "out=$out"

# An explicit --transport is the caller's answer; AUTO does not get to overrule it.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi" --transport cmux)
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 + an explicit --transport cmux stays on cmux's chain" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi" --headless)
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "headless" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 + --headless goes headless, and never preflights herdr" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# HOTLINE_FORCE_HEADLESS is the ambient form of the same instruction. It is read by
# check-cmux.sh, so without its own clause here the auto path would have selected
# herdr before that variable was ever consulted.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        "HOTLINE_FORCE_HEADLESS=1" -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "headless" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 + HOTLINE_FORCE_HEADLESS=1 goes headless too" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# EXACTLY '1'. A looser test would let a `HOTLINE_TRANSPORT_AUTO=0` left in a
# profile enable the very thing it was written to turn off.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=0" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]] && [[ ! -s "$t/herdr.log" ]]
check "HOTLINE_TRANSPORT_AUTO=0 does not enable it (the opt-in is exactly '1')" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --transport headless is just another way to say --headless.
t=$(new_env)
stub_headless_claude "$t"
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
# `sent` FORWARDED into the error, because the recovery text tells the model to read it
# — and an error that dropped it left that advice unactionable on the one failure where
# double-delivery is the risk (claude-plugins-zh7p).
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]]
check "…carrying the delivery's own \`sent\`, which decides whether re-dialing is safe" $? \
  "out=$out"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"\`sent\` field is true"* ]]
check "…and a recovery that states the value rather than pointing at a result the model never sees" $? \
  "out=$out"
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

# The same field on a PRE-SUBMIT refusal: sent:false, so the caller is free to re-dial.
# Hardcoding it either way would make it worse than absent.
t=$(new_env)
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" "HERDR_STUB_GET_READY=false" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a pre-submit refusal reports sent:FALSE on the same error field" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

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
echo "6. Follow-ups (reuse) — the named agent IS the session:"
# ===========================================================================
# A herdr follow-up re-targets the agent the cache already holds. It must NOT
# launch anything: a second callee would have none of the prior conversation, and
# a second host for a live session is exactly the surface-stacking the cmux reuse
# path exists to prevent.

HERDR_REUSE="$SCRIPTS/herdr-reuse-agent.sh"

# The caller-side cache dial.sh reads: one connection for $t/target, keyed by the
# REALPATH (which is what session-cache.sh canonicalizes to).
stage_cache() {  # stage_cache <scratch> <session-id> <host-handle|''>
  local t="$1" sid="$2" handle="$3"
  mkdir -p "$t/home/.agents-hotline/sessions"
  jq -nc --arg t "$(cd "$t/target" && pwd -P)" --arg s "$sid" --arg h "$handle" \
    '{caller_session_id:"caller-dial-1",
      connections:{($t): ({session_id:$s, mode:"work_order", started:1,
                           last_contact:1, exchange_count:1,
                           last_call_id:"prior-nonce"}
        + (if $h == "" then {} else {surface_ref:$h} end))}}' \
    > "$t/home/.agents-hotline/sessions/caller-dial-1.json"
}

CACHED_AGENT="hotline-target-a1b2c3"
CACHED_SID="prior-session-1"

# --- the happy path, end to end through dial.sh -----------------------------
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" ]]
check "a herdr dial into an already-cached session CONNECTS as a follow-up" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"agent prompt $CACHED_AGENT"* ]]
check "…delivered by \`agent prompt <cached-name>\`, re-targeting the live agent" $? \
  "herdr calls: $log"
! grep -qE 'agent start|pane split' <(printf '%s' "$log")
check "…and NOT by a fresh \`agent start\` / \`pane split\` (no second callee, no lost context)" $? \
  "herdr calls: $log"
! grep -q 'pane close' <(printf '%s' "$log")
check "…with no superseded-host cleanup: the same agent is reused, so nothing is orphaned" $? \
  "herdr calls: $log"

[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "$CACHED_AGENT" \
   && "$(jq -r '.remote_session_id' <<<"$out" 2>/dev/null)" == "$CACHED_SID" \
   && -n "$(jq -r '.call_id // empty' <<<"$out" 2>/dev/null)" ]]
check "…keeping .surface_ref / .remote_session_id / .call_id stable in shape" $? "out=$out"
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]]
check "…and recording no fallback, because nothing was worked around" $? "out=$out"
# The proof tier herdr-reuse-agent.sh reported, forwarded like the cmux twin's. A
# reader comparing the two transports cannot tell a dropped field from a delivery
# nothing could prove.
[[ "$(jq -r '.confirmed // "<absent>"' <<<"$out" 2>/dev/null)" == "transcript" ]]
check "…and forwarding the delivery's proof tier (.confirmed), as the cmux path does" $? "out=$out"

# The RAW message, not the ringing invocation: this session already ran first
# contact, and re-invoking the slash command would re-run its setup mid-call.
DELIVERED="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$CACHED_SID.jsonl"
grep -q 'and now step 2' "$DELIVERED" 2>/dev/null \
  && ! grep -q 'hotline-ringing' "$DELIVERED" 2>/dev/null
check "…delivering the RAW follow-up, never re-wrapped with the ringing invocation" $? \
  "delivered: $(cat "$DELIVERED" 2>/dev/null | head -c 300)"

NEW_NONCE=$(jq -r '.call_id' <<<"$out" 2>/dev/null)
[[ -n "$NEW_NONCE" && "$NEW_NONCE" != "prior-nonce" ]] \
  && grep -qF "[CALL_ID: $NEW_NONCE]" "$DELIVERED" 2>/dev/null
check "…led by a FRESH nonce, so the prior exchange's STATUS lines cannot be read as this turn's" $? \
  "call_id=$NEW_NONCE prior=prior-nonce delivered=$(head -c 200 "$DELIVERED" 2>/dev/null)"

REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
conn() { jq -r --arg t "$(cd "$t/target" && pwd -P)" ".connections[\$t].$1 // \"<absent>\"" "$REG" 2>/dev/null; }
[[ "$(conn exchange_count)" == "2" && "$(conn session_id)" == "$CACHED_SID" \
   && "$(conn surface_ref)" == "$CACHED_AGENT" && "$(conn last_call_id)" == "$NEW_NONCE" ]]
check "…and the cache bumps the exchange while keeping the same session and agent" $? \
  "registry: $(cat "$REG" 2>/dev/null)"

# --- the cached agent has died → a fresh launch, said out loud ---------------
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        "HERDR_STUB_GONE_NAMES=$CACHED_AGENT" "HERDR_STUB_NEW_PANE=w1:p7" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]]
check "a cached agent that no longer resolves falls back to a fresh launch" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
fb=$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)
[[ "$fb" == *"herdr-agent-reuse→fresh"* && "$fb" == *"no live herdr agent answers"* ]]
check "…recording the fallback with herdr's own reason" $? "fallbacks=$fb"
[[ "$fb" == *"WITHOUT the prior context"* ]]
check "…and stating the cost outright: herdr cannot re-host a session, so the callee is amnesiac" $? \
  "fallbacks=$fb"
grep -qE 'agent start' <(tr -d '\\' < "$t/herdr.log")
check "…having actually started a new agent" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
! grep -q 'pane close' <(tr -d '\\' < "$t/herdr.log")
check "…and closed nothing: a dead agent leaves nothing live to supersede" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

NEW_AGENT=$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)
NEW_SID=$(jq -r '.remote_session_id' <<<"$out" 2>/dev/null)
[[ "$NEW_AGENT" == hotline-* && "$NEW_AGENT" != "$CACHED_AGENT" \
   && -n "$NEW_SID" && "$NEW_SID" != "$CACHED_SID" ]]
check "…reporting the NEW agent name and the NEW callee session" $? \
  "surface_ref=$NEW_AGENT session=$NEW_SID"
[[ "$fb" == *"callee-session-changed(${CACHED_SID}→${NEW_SID}"* ]]
check "…and the session change itself is reported, not just implied" $? "fallbacks=$fb"
REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
[[ "$(conn session_id)" == "$NEW_SID" && "$(conn surface_ref)" == "$NEW_AGENT" ]]
check "…with the cache re-keyed, so the NEXT follow-up addresses the live callee" $? \
  "registry: $(cat "$REG" 2>/dev/null)"

# THE PAYLOAD IS RE-RENDERED AS FIRST CONTACT. This callee is brand new: it never
# loaded the ringing skill, so the follow-up-shaped prompt the reuse path would have
# sent lands as prose — no STATUS line ever emitted, and the caller's waiter spends
# its whole budget on a protocol nobody engaged. cmux never reaches this state (its
# fresh launch --resumes the same session); herdr cannot re-host a session at all.
FRESH_DELIVERED="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$NEW_SID.jsonl"
grep -q 'hotline-ringing' "$FRESH_DELIVERED" 2>/dev/null
check "…and the fresh callee is RUNG: its delivered prompt carries the ringing invocation" $? \
  "delivered: $(head -c 400 "$FRESH_DELIVERED" 2>/dev/null)"
grep -q 'and now step 2' "$FRESH_DELIVERED" 2>/dev/null \
  && grep -q 'MODE: work_order' "$FRESH_DELIVERED" 2>/dev/null
check "…with the follow-up message and the protocol tags beneath it" $? \
  "delivered: $(head -c 400 "$FRESH_DELIVERED" 2>/dev/null)"
# .first_contact still answers "did this dial have a cached session to work from",
# and this one did. Only the prompt shape and the --name changed.
[[ "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "false" ]]
check "…while the emitted first_contact stays false: the cache entry was real" $? "out=$out"
# --name reaches this launch too. herdr-call-async.sh mints the agent name from the
# session name when it has one and from the callee's CWD when it does not, so a
# fallback launch without it produces a bare cwd-slug name — the one agent in
# `herdr agent list` that does not say which call opened it.
[[ "$NEW_AGENT" != "hotline-$(basename "$t/target")-"* ]]
check "…and the launch passes --name, so the new agent is not named off the cwd slug" $? \
  "agent=$NEW_AGENT (cwd slug would be hotline-$(basename "$t/target")-*)"

# --- a follow-up into a BLOCKED cached agent, THROUGH dial.sh ----------------
# The orphan the direct-script tests above cannot see: dial.sh used to answer a
# refused reuse by starting a SECOND callee and re-keying the cache to it, leaving
# the blocked agent live, holding the only copy of the conversation, and no longer
# addressable through hotline (claude-plugins-7wze.13). It fails the dial instead.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" "HERDR_STUB_STATUS=blocked" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]]
check "a follow-up into a BLOCKED herdr agent FAILS the dial (stage=transport)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
log=$(tr -d '\\' < "$t/herdr.log")
! grep -qE 'agent start|pane split' <(printf '%s' "$log")
check "…starting no second callee, so the blocked agent is not orphaned" $? \
  "herdr calls: $log"
! grep -q 'agent prompt' <(printf '%s' "$log")
check "…and submitting nothing into the gate it is sitting on" $? "herdr calls: $log"
REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
[[ "$(conn surface_ref)" == "$CACHED_AGENT" && "$(conn session_id)" == "$CACHED_SID" \
   && "$(conn exchange_count)" == "1" ]]
check "…leaving the cache pointed at the blocked agent, NOT re-keyed to a new one" $? \
  "registry: $(cat "$REG" 2>/dev/null)"

# The actionable half of the reason has to SURVIVE. reason_of used to cut at 140,
# which severed `herdr agent attach <name>` off the end — the one thing a reader of
# this error can act on.
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"herdr agent attach $CACHED_AGENT"* ]]
check "…with the attach hint intact in .detail (reason_of no longer severs it)" $? \
  "detail=$(jq -r '.detail' <<<"$out" 2>/dev/null)"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"re-dial exactly as you just did"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"context intact"* ]]
check "…and a recovery that says the context is still there once a human clears it" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"

# A BLINK must not fail the dial: blocked on the first read, clear on the confirming
# one, and the follow-up lands in the same agent as though nothing happened.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" "HERDR_STUB_BLOCKED_ONCE=1" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "$CACHED_AGENT" ]]
check "a blocked BLINK on a follow-up neither fails the dial nor starts a second callee" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
! grep -qE 'agent start|pane split' <(tr -d '\\' < "$t/herdr.log")
check "…reusing the cached agent, exactly as it would have without the blink" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- a cached session with no host handle at all -----------------------------
# A prior headless exchange leaves no host to re-target. Fresh launch, and the
# fallback says the context is gone rather than letting a caller assume continuity.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" ""
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached --boot-timeout 5)
fb=$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$fb" == *"herdr-agent-reuse-skipped(no-cached-host-handle"* ]]
check "a cached session with no host handle → fresh launch, with the skip recorded" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "false" ]] \
  && [[ "$fb" == *"without the prior context"* ]]
check "…still first_contact:false (the cache entry is real; only the host is missing), and the loss is named" $? \
  "out=$out"
# The reuse script is never invoked here, so nothing probes an agent BEFORE the
# launch: every `agent get` in this log belongs to the fresh call (the launcher's
# name-collision check, then delivery's own liveness check).
! grep -q 'agent get' <(sed -n '1,/pane split/p' <(tr -d '\\' < "$t/herdr.log")) \
  && grep -q 'agent start' <(tr -d '\\' < "$t/herdr.log")
check "…and no liveness probe was made before the launch: there was no handle to probe" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- herdr-reuse-agent.sh directly ------------------------------------------
# A BLOCKED agent refuses the reuse. This is the herdr analogue of cmux's
# post-interrupt refusal: a work order submitted into a permission gate ANSWERS
# the gate instead of starting a turn.
#
# And it is NOT fallback:fresh (claude-plugins-7wze.13). That agent is live and
# holds the only copy of this conversation, so answering with a fresh callee
# strands it — see TWO STATES REFUSE THE REUSE in the script.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      bash "$HERDR_REUSE" --agent hotline-b-1 --session s-b --prompt "next thing" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.blocked' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.agent' <<<"$out" 2>/dev/null)" == "hotline-b-1" \
   && "$(jq -r '.fallback // "none"' <<<"$out" 2>/dev/null)" == "none" ]]
check "reuse into a BLOCKED agent → blocked:true, NOT fallback:fresh (a fresh callee would strand it)" $? \
  "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…before submitting anything" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(grep -c 'agent get hotline-b-1' <(tr -d '\\' < "$t/herdr.log"))" -ge 2 ]]
check "…and only after a CONFIRMING second read, so a blink cannot fail a good follow-up" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The blink itself: blocked on the first read, clear on the confirming one. The
# follow-up proceeds, because nothing was ever actually wrong with it.
t=$(new_env)
wrap_herdr_transcript "$t" "blink-sess"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_BLOCKED_ONCE=1 \
      bash "$HERDR_REUSE" --agent hotline-b-2 --session blink-sess --prompt "next thing" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.delivery' <<<"$out" 2>/dev/null)" == "prompt" \
   && "$(jq -r '.blocked // false' <<<"$out" 2>/dev/null)" == "false" ]]
check "a blocked BLINK the confirming read refutes → the follow-up goes through" $? "out=$out"

# Blocked, then gone: it exited while waiting on that input. Nothing live holds the
# context any more, so this IS a legitimate fallback rather than a dial failure.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HERDR_STUB_GONE_AFTER=1 \
      bash "$HERDR_REUSE" --agent hotline-b-3 --session s-b3 --prompt "next" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.fallback' <<<"$out" 2>/dev/null)" == "fresh" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"exited while waiting"* ]]
check "an agent that was blocked and has since EXITED falls back (nothing live to strand)" $? \
  "out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_GONE=1 \
      bash "$HERDR_REUSE" --agent hotline-g-1 --session s-g --prompt "next" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.fallback' <<<"$out" 2>/dev/null)" == "fresh" ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"exited"* ]]
check "reuse into a GONE agent refuses with fallback:fresh, naming the exit" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and submits nothing" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The call-dir contract of a reused call: identical to a launched one, minus the
# launch — so every downstream reader treats it the same.
t=$(new_env)
wrap_herdr_transcript "$t" "reuse-sess-1"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_REUSE" --agent hotline-r-live --session reuse-sess-1 \
        --prompt "the follow-up" --cwd "$t/target" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && "$(jq -r '.confirmed' <<<"$out" 2>/dev/null)" == "transcript" \
   && "$(jq -r '.delivery' <<<"$out" 2>/dev/null)" == "prompt" ]]
check "a live agent → a call_dir with the delivery confirmed by transcript" $? "out=$out"
[[ "$(cat "$cd_path/transport.txt" 2>/dev/null)" == "herdr" \
   && "$(cat "$cd_path/herdr_agent.txt" 2>/dev/null)" == "hotline-r-live" \
   && "$(cat "$cd_path/keep_workspace.txt" 2>/dev/null)" == "true" \
   && "$(cat "$cd_path/session_id.txt" 2>/dev/null)" == "reuse-sess-1" ]]
check "…wired like the launcher's call dir (transport / agent / keep / session)" $? \
  "call_dir: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
[[ ! -f "$cd_path/herdr_pane.txt" && ! -f "$cd_path/surface_ref.txt" \
   && ! -f "$cd_path/workspace_ref.txt" ]]
check "…and names no pane and no cmux handle (it placed no host)" $? \
  "call_dir: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
[[ ! -f "$cd_path/pending_paste.md" ]]
check "…with the delivered payload removed once confirmed" $? \
  "call_dir: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"

# The same canonicalization the launcher does, and for the same reason: Claude Code
# encodes the cwd it RESOLVED, and every consumer derives the transcript path from
# this file.
t=$(new_env)
ln -s "$t/target" "$t/linked"
wrap_herdr_transcript "$t" "reuse-sess-2"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_REUSE" --agent hotline-r-link --session reuse-sess-2 \
        --prompt "hi" --cwd "$t/linked" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ "$(cat "$cd_path/cwd.txt" 2>/dev/null)" == "$(cd "$t/target" && pwd -P)" ]]
check "reuse canonicalizes cwd.txt too, so a symlinked target still resolves" $? \
  "cwd.txt='$(cat "$cd_path/cwd.txt" 2>/dev/null)' want='$(cd "$t/target" && pwd -P)'"

# Submitted and unconfirmable is NOT a fallback: the payload may already be queued,
# so re-delivering it into a fresh callee would run the work order twice.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_REUSE" --agent hotline-r-unconf --session reuse-sess-3 \
        --prompt "hi" --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.undelivered' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.fallback // empty' <<<"$out" 2>/dev/null)" == "" ]]
check "submitted but unconfirmed → undelivered:true, never fallback:fresh (no double-run)" $? \
  "out=$out"
pf=$(jq -r '.prompt_file // empty' <<<"$out" 2>/dev/null)
[[ -s "$pf" ]] && grep -q 'hi' "$pf"
check "…keeping the only copy of the prompt on disk for recovery" $? "prompt_file=$pf"

# …and dial.sh turns that into a stage=deliver ERROR with an explicit do-not-re-dial.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"Do NOT re-dial"* ]]
check "an unconfirmable FOLLOW-UP errors at stage=deliver, telling the caller not to re-dial" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
! grep -qE 'agent start|pane split' <(tr -d '\\' < "$t/herdr.log")
check "…and never launches a second callee behind it" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# ===========================================================================
echo ""
echo "7. Blocked-state reporting — a human is needed, not more time:"
# ===========================================================================
# herdr reports `blocked` natively: the callee is waiting on INPUT (a permission
# gate, or a genuine question). Spending the full 30-minute budget on that and then
# calling it a timeout sends a reader hunting a slow work order instead of a dialog
# box. It is NOT a new terminal STATUS — the protocol is untouched; the LIFECYCLE
# is saying why no STATUS is coming.

t=$(new_env)
NONCE="b10cked0000aaaa1"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-1 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "reading the repo"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -eq 5 ]]
check "a blocked settle with no terminal STATUS → exit 5, its own outcome" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
grep -q 'waiting on INPUT' "$t/err.txt" && grep -q 'agent attach hotline-blk-1' "$t/err.txt"
check "…saying it is waiting on input and how to look at it" $? "stderr=$(cat "$t/err.txt")"
! grep -qi 'timed out' "$t/err.txt"
check "…and never calling it a timeout" $? "stderr=$(cat "$t/err.txt")"
[[ -s "$cd_path/waiter_timeout.txt" ]] && grep -q 'settle=blocked' "$cd_path/waiter_timeout.txt"
check "…marked RESUMABLE, so re-running after a human unblocks it reads the answer" $? \
  "marker=$(cat "$cd_path/waiter_timeout.txt" 2>/dev/null)"
! grep -q 'pane close' "$t/herdr.log" 2>/dev/null
check "…leaving the agent live (it is mid-question; closing it would end the call)" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The answer outranks the lifecycle. A callee that emits its terminal STATUS and
# then blocks on the NEXT thing it wants to do has answered us.
t=$(new_env)
NONCE="b10cked0000aaaa2"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-2 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" WORK_COMPLETE "done, and now asking about something else"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 30 2>"$t/err.txt"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"done, and now asking"* ]]
check "a blocked agent that ALREADY answered still exits 0 with the answer" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

# A blocked callee with no transcript at all is still blocked, and that is the more
# useful thing to say than "the prompt never reached the agent" — a gate raised
# before the callee could record anything looks identical to a lost delivery.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-3 "herdr-sess" "n-blk3" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -eq 5 ]] && grep -q 'waiting on INPUT' "$t/err.txt"
check "blocked with no transcript reports the block, not a phantom delivery failure" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"

# …but that path confirms too, like every other one that ends a call on `blocked`.
# It used to act on a SINGLE read — the one exception, and the reason the documented
# "always re-probed" promise was not actually true (claude-plugins-7wze.13). A blink
# refuted here now reports what the confirming probe found instead.
t=$(new_env)
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-5 "herdr-sess" "n-blk5" "$t/target"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_BLOCKED_ONCE=1 \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 600 2>"$t/err.txt"); rc=$?
[[ $rc -eq 1 ]] && grep -q 'No transcript after' "$t/err.txt" \
  && ! grep -q 'waiting on INPUT' "$t/err.txt"
check "a blocked BLINK with no transcript is NOT reported as blocked (the probe refuted it)" $? \
  "rc=$rc stderr=$(cat "$t/err.txt")"
[[ "$(grep -c 'agent get hotline-blk-5' <(tr -d '\\' < "$t/herdr.log"))" -ge 2 ]]
check "…because the no-transcript path re-probes now, like every other blocked exit" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# A blocked BLINK is not a verdict: the state is re-probed before the call ends, so
# a gate that cleared itself leaves the wait running.
t=$(new_env)
NONCE="b10cked0000aaaa4"
cd_path="$t/call"
stage_herdr_dir "$cd_path" hotline-blk-4 "herdr-sess" "$NONCE" "$t/target"
transcript_with "$t/home/.claude/projects/$(encode_cwd "$t/target")/herdr-sess.jsonl" \
  "$NONCE" "" "still working"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=working \
      HERDR_STUB_WAIT_STATUS=blocked \
      HOTLINE_POLL_SLEEP=0 HOTLINE_HERDR_WAIT_SLICE_MS=50 \
      bash "$WAIT_RESPONSE" "$cd_path" --timeout 6 2>"$t/err.txt"); rc=$?
[[ $rc -eq 1 ]] && grep -q 'Timed out' "$cd_path/error.txt"
check "a blocked settle the confirming probe does not reproduce keeps waiting" $? \
  "rc=$rc error=$(cat "$cd_path/error.txt" 2>/dev/null)"

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

[[ "$SKILL_FLAT" == *'HOTLINE_HERDR_SPLIT_DIRECTION=right|down`** — which way that split goes (default `right`)'* ]] \
  && grep -q 'HOTLINE_HERDR_SPLIT_DIRECTION:-right' "$HERDR_ASYNC"
check "SKILL.md's split-direction default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_SPLIT_DIRECTION:-[a-z]*' "$HERDR_ASYNC")"

[[ "$SKILL_FLAT" == *'freshly split pane (default 1)'* ]] \
  && grep -q 'HOTLINE_HERDR_PANE_SETTLE:-1}' "$HERDR_ASYNC"
check "SKILL.md's pane-settle default matches herdr-call-async.sh" $? \
  "script: $(grep -o 'HOTLINE_HERDR_PANE_SETTLE:-[0-9]*' "$HERDR_ASYNC")"

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
