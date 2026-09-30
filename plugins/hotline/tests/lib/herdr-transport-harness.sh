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
#
# This file is the shared harness for the herdr-transport-*_test.sh shards. SOURCE
# it, don't execute it: it sets up the poison PATH, the stubs, the sandboxed env
# and the pass/fail counters, and herdr_suite_finish prints the result and exits.
# The shards split one suite along its section numbers, so a case keeps the
# number it has always had.
# =============================================================================
# Keep standalone runs under the system temp directory while honoring the runner.
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT=${TMP_ROOT%/}
export TMP_ROOT
PASS=0
FAIL=0
FAILED_CASES=()

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$HOTLINE_DIR/skills/dial/scripts"
CHECK_HERDR="$SCRIPTS/check-herdr.sh"
HERDR_ASYNC="$SCRIPTS/herdr-call-async.sh"
HERDR_PROMPT="$SCRIPTS/herdr-prompt.sh"
WAIT_SESSION="$SCRIPTS/wait-for-session.sh"
WAIT_RESPONSE="$SCRIPTS/wait-for-response.sh"
DIAL="$SCRIPTS/dial.sh"
HERDR_REUSE="$SCRIPTS/herdr-reuse-agent.sh"

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
ROOT="$(mktemp -d "$TMP_ROOT"/hotline-herdr-test-XXXXXX)"
POISON_BIN="$ROOT/poison-bin"
POISON_LOG="$ROOT/violations"
mkdir -p "$POISON_BIN"
for _poison in herdr cmux claude dirmap ssh; do
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
# The ssh ControlMaster socket directory. Pointed at this suite's own root for the
# same reason HOTLINE_CALL_HOME is — and because the real default is /tmp, which the
# remote layer picks deliberately (a unix socket address caps at 104 bytes) and
# which a test has no business writing into.
HOTLINE_SSH_CONTROL_HOME=$(mktemp -d /tmp/hh-XXXXXX)
export HOTLINE_SSH_CONTROL_HOME
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
      HOTLINE_HERDR_PANE HOTLINE_HERDR_SPLIT_DIRECTION \
      HOTLINE_HERDR_PLACEMENT HOTLINE_HERDR_WORKSPACE HOTLINE_HERDR_TAB_LABEL \
      2>/dev/null || true

cleanup() { rm -rf "$ROOT" "$HOTLINE_SSH_CONTROL_HOME"; }
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
#   HERDR_STUB_PANE_WS        the workspace_id `pane get` reports for the anchor
#                             (default: the pane id's own `wN` prefix, as the real
#                             CLI does — pane ids are workspace-qualified)
#   HERDR_STUB_PANE_GET_FAIL=1 `pane get` returns a server error
#   HERDR_STUB_TAB_PANE       the root pane `tab create` returns (default w1:p7)
#   HERDR_STUB_TAB_ID         the tab id `tab create` returns (default w1:t7)
#   HERDR_STUB_TAB_FAIL=1     `tab create` returns a server error
#   HERDR_STUB_AGENT_TAB      the tab_id `agent get` reports (default: the agent
#                             pane's own `wN` prefix + `:t1`)
#   HERDR_STUB_TAB_PANE_COUNT the pane_count `tab get` reports (default 2 — the
#                             SPLIT shape, where the callee shares the caller's tab)
#   HERDR_STUB_TAB_GET_FAIL=1 `tab get` returns a server error
#   HERDR_STUB_TAB_NO_PANE=1  `tab create` succeeds but reports no root pane id
#   HERDR_STUB_WORKSPACES     space-separated `<id>:<label>` pairs `workspace list`
#                             reports (default: none — every label is absent)
#   HERDR_STUB_NEW_WS         the workspace_id `workspace create` returns (default w5)
#   HERDR_STUB_WS_CREATE_FAIL=1 `workspace create` returns a server error
#   HERDR_STUB_BUSY_TIMES=N   the first N `agent start` calls fail agent_pane_busy
#   HERDR_STUB_PANE_BUSY_TIMES=N the first N `pane process-info` calls report a
#                             foreground command on top of the shell — the pane NOT
#                             at its prompt, which is what the readiness poll waits
#                             out before it ever calls `agent start`
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

  "pane process-info")
    # Readiness, the way the real CLI reports it: the pane is at its interactive
    # prompt exactly when the foreground process group IS the shell. A busy pane
    # answers with a command's pgid instead.
    [[ "${HERDR_STUB_PROCINFO_FAIL:-}" == "1" ]] && err pane_not_found "no such pane"
    PBUSY="${HERDR_STUB_PANE_BUSY_TIMES:-0}"
    PSEEN=0; [[ -f "$ST/pane_busy" ]] && PSEEN=$(cat "$ST/pane_busy")
    PANE_ARG=""; _prev=""
    for _i in "$@"; do [[ "$_prev" == "--pane" ]] && { PANE_ARG="$_i"; break; }; _prev="$_i"; done
    FG="${HERDR_STUB_SHELL_PID:-4242}"
    if [[ "$PSEEN" -lt "$PBUSY" ]]; then
      echo $((PSEEN + 1)) > "$ST/pane_busy"
      FG=9999
    fi
    jq -nc --arg p "$PANE_ARG" --argjson fg "$FG" \
           --argjson sh "${HERDR_STUB_SHELL_PID:-4242}" \
      '{id:"cli:pane:process_info",result:{type:"pane_process_info",
         process_info:{pane_id:$p,shell_pid:$sh,foreground_process_group_id:$fg,
                       foreground_processes:[]}}}'
    exit 0 ;;

  "pane close") echo '{"id":"cli:pane:close","result":{"closed":true}}'; exit 0 ;;

  "pane get")
    [[ "${HERDR_STUB_PANE_GET_FAIL:-}" == "1" ]] && err pane_not_found "no such pane $3"
    # Pane ids are workspace-qualified (`w6:p1`), and the real CLI reports the
    # owning workspace on the pane. Derive it the same way rather than inventing an
    # id a caller could not have asked about.
    jq -nc --arg p "$3" --arg ws "${HERDR_STUB_PANE_WS:-${3%%:*}}" \
      '{id:"cli:pane:get",result:{pane:{pane_id:$p,workspace_id:$ws,tab_id:($ws + ":t1")},type:"pane_info"}}'
    exit 0 ;;

  "tab create")
    [[ "${HERDR_STUB_TAB_FAIL:-}" == "1" ]] && err tab_create_failed "no such workspace"
    TP="${HERDR_STUB_TAB_PANE:-w1:p7}"
    [[ "${HERDR_STUB_TAB_NO_PANE:-}" == "1" ]] && TP=""
    jq -nc --arg p "$TP" --arg tid "${HERDR_STUB_TAB_ID:-w1:t7}" \
      '{id:"cli:tab:create",result:{type:"tab_created",
         tab:{tab_id:$tid,pane_count:1},
         root_pane:(if $p == "" then {} else {pane_id:$p,tab_id:$tid} end)}}'
    exit 0 ;;

  "tab close") echo '{"id":"cli:tab:close","result":{"type":"ok"}}'; exit 0 ;;

  "workspace list")
    WSJSON="[]"
    for _w in ${HERDR_STUB_WORKSPACES:-}; do
      WSJSON=$(jq -c --arg id "${_w%%:*}" --arg l "${_w#*:}" \
        '. + [{workspace_id:$id,label:$l}]' <<<"$WSJSON")
    done
    jq -nc --argjson ws "$WSJSON" '{id:"cli:workspace:list",result:{type:"workspace_list",workspaces:$ws}}'
    exit 0 ;;

  "workspace create")
    [[ "${HERDR_STUB_WS_CREATE_FAIL:-}" == "1" ]] && err workspace_create_failed "could not create"
    NW="${HERDR_STUB_NEW_WS:-w5}"
    jq -nc --arg ws "$NW" '{id:"cli:workspace:create",result:{type:"workspace_created",
      workspace:{workspace_id:$ws},root_pane:{pane_id:($ws + ":p1"),tab_id:($ws + ":t1")},
      tab:{tab_id:($ws + ":t1")}}}'
    exit 0 ;;

  "agent start")
    NAME="$3"
    # A start into a pane that is NOT at its prompt is refused, the way the real
    # herdr refuses one. Driven off the SAME counter `pane process-info` reports
    # from, so a launcher that never asks about readiness cannot get past it — which
    # is the production failure this fixture exists to reproduce.
    if [[ -n "${HERDR_STUB_PANE_BUSY_TIMES:-}" ]]; then
      PSEEN=0; [[ -f "$ST/pane_busy" ]] && PSEEN=$(cat "$ST/pane_busy")
      if [[ "$PSEEN" -lt "$HERDR_STUB_PANE_BUSY_TIMES" ]]; then
        TPANE=""; _prev=""
        for _i in "$@"; do [[ "$_prev" == "--pane" ]] && { TPANE="$_i"; break; }; _prev="$_i"; done
        printf '{"error":{"code":"agent_pane_busy","message":"agent target pane %s is not an available shell"}}\n' "$TPANE" >&2
        exit 1
      fi
    fi
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
    # tab_id, which the real CLI reports on every agent. Derived from the pane's
    # workspace prefix by default, as a split's pane is: a split SHARES the
    # anchor's tab, which is why the default tab below carries two panes.
    TAB="${HERDR_STUB_AGENT_TAB:-${PANE%%:*}:t1}"
    [[ -z "$PANE" ]] && TAB="${HERDR_STUB_AGENT_TAB:-}"
    jq -nc --arg n "$NAME" --arg s "$STATUS" --arg sid "$SID" \
           --arg ready "$READY" --arg pane "$PANE" --arg tab "$TAB" \
      '{id:"cli:agent:get",result:{agent:({name:$n,agent:"claude",agent_status:$s,
         agent_session:{agent:"claude",kind:"id",source:"herdr:claude",value:$sid}}
         + (if $ready == "omit" then {} else {interactive_ready:($ready == "true")} end)
         + (if $tab == "" then {} else {tab_id:$tab} end)
         + (if $pane == "" then {} else {pane_id:$pane} end))}}'
    exit 0 ;;

  "tab get")
    [[ "${HERDR_STUB_TAB_GET_FAIL:-}" == "1" ]] && err tab_not_found "no such tab $3"
    # TWO PANES BY DEFAULT — the split shape. A tab hotline created for a callee
    # holds that callee alone (pane_count 1); the default placement is a split,
    # whose pane shares the caller's tab, and renaming THAT retitles the caller.
    jq -nc --arg t "$3" --argjson n "${HERDR_STUB_TAB_PANE_COUNT:-2}" \
      '{id:"cli:tab:get",result:{type:"tab_info",tab:{tab_id:$t,pane_count:$n,label:"1"}}}'
    exit 0 ;;

  # Kept although hotline never calls it: the "renames nothing" contract guards
  # assert an ABSENCE from the log, and a stub that could not answer a rename
  # would make those guards pass for the wrong reason.
  "tab rename")
    echo '{"id":"cli:tab:rename","result":{"type":"ok"}}'
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

# ---------------------------------------------------------------------------
# The ssh stub. It LOGS the hop and then EVALs the remote command string in this
# shell, which is a faithful simulation rather than a shortcut: the remote layer
# single-quotes every argument precisely because ssh hands the joined string to the
# remote user's SHELL, so a shell evaluating that string is exactly what happens on
# the far side. It is also what makes every knob of the herdr stub above work
# unchanged one hop away — `ssh host 'herdr pane list'` runs this file's herdr stub
# — so a remote case tests the ssh plumbing without a second copy of herdr.
#
# The "remote box" is therefore this case's own sandbox: $HOME is $t/home and the
# callee cwd is $t/target, which is what lets the transcript assertions below check
# a path the remote layer derived from a $HOME and a realpath it ASKED for.
#
#   SSH_LOG               append every hop here as `<target> :: <command>` (required)
#   SSH_STUB_FAIL=1       ssh itself fails (rc 255), as an unresolvable host does
#   SSH_STUB_SLEEP=N      sleep before running, so `timeout` kills the hop
#   SSH_STUB_TAILSCALE=1  print Tailscale's check-mode notice on BOTH streams ahead
#                         of the real output — the lines nothing may parse as data
#   SSH_STUB_NO_HERDR=1   run the remote command with a PATH that has no herdr,
#                         modelling a box where herdr is not installed
#   SSH_STUB_NO_CLAUDE=1  make `command -v claude` fail on the far side. A knob and
#                         not a PATH edit, because `command -v` never EXECUTES
#                         anything: the suite's poison `claude` satisfies it, so an
#                         absence has to be modelled rather than arranged
#   SSH_STUB_HOME=<dir>   the REMOTE $HOME, which every transcript case sets to a
#                         directory the local $HOME is NOT. Without that the two
#                         coincide, and "ask the remote box for its $HOME" becomes
#                         indistinguishable from "assume the caller's" — a mutation
#                         that drops the ssh hop entirely would still pass
# ---------------------------------------------------------------------------
make_ssh_stub() {  # <bin-dir>
  mkdir -p "$1"
  cat > "$1/ssh" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@"); CMD=""; TARGET=""; i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  a="${ARGS[$i]}"
  case "$a" in
    -o|-O)  i=$((i+2)); continue ;;
    -*)     i=$((i+1)); continue ;;
    *) if [[ -z "$TARGET" ]]; then TARGET="$a"; else CMD="$a"; fi; i=$((i+1)) ;;
  esac
done
printf '%s :: %s\n' "$TARGET" "$CMD" >> "${SSH_LOG:?SSH_LOG not set}"
# THE FULL ARGV TOO, one line per invocation, in a second log beside the first.
# The parse above throws every option away, so nothing asserted on THAT log can
# witness one: delete `-o BatchMode=yes` (a hop that can then sit on a password
# prompt) or `-n` (a hop that eats its caller's stdin) from herdr-remote.sh and the
# parsed log is byte-identical. This log is what pins them, and it is read from BOTH
# ends — the delivery block covers the hops hotline_remote_run makes, the fetch
# block covers hotline_remote_fetch_transcript's. One option set, two callers, so
# either end alone would leave the other's hop unpinned.
printf '%s\n' "$*" >> "${SSH_LOG}.argv"
if [[ "${SSH_STUB_FAIL:-}" == "1" ]]; then
  echo "ssh: Could not resolve hostname ${TARGET#*@}: nodename nor servname provided" >&2
  exit 255
fi
if [[ "${SSH_STUB_TAILSCALE:-}" == "1" ]]; then
  echo "# Tailscale SSH requires an additional check. To authenticate, visit https://login.tailscale.com/a/f00dcafe"
  echo "To authenticate, visit https://login.tailscale.com/a/f00dcafe" >&2
fi
[[ -n "${SSH_STUB_SLEEP:-}" ]] && sleep "$SSH_STUB_SLEEP"
[[ -z "$CMD" ]] && exit 0
[[ "${SSH_STUB_NO_HERDR:-}" == "1" ]] && PATH="/usr/bin:/bin"
[[ -n "${SSH_STUB_HOME:-}" ]] && export HOME="$SSH_STUB_HOME"
if [[ "${SSH_STUB_NO_CLAUDE:-}" == "1" ]]; then
  command() { if [[ "${2:-}" == "claude" ]]; then return 1; fi; builtin command "$@"; }
fi
eval "$CMD"
STUB
  chmod +x "$1/ssh"
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
  make_ssh_stub "$t/bin"
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

# ---------------------------------------------------------------------------
# Helpers more than one shard calls.
# ---------------------------------------------------------------------------

# The startup trust dialog as claude renders it (claude-plugins-59ry).
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

# --label is REQUIRED by dial.sh, so the helper supplies a default FIRST — a case
# that passes its own --label comes later in argv and wins, since the parse loop
# assigns on every occurrence.
dial() {  # dial <scratch> <extra-env...> -- <dial args...>
  local t="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" SSH_LOG="$t/ssh.log" \
      HOTLINE_CALLER_SESSION_ID="caller-dial-1" \
      HOTLINE_PENDING_DIR="$t/pending" \
      ${envs[@]+"${envs[@]}"} bash "$DIAL" --label "probe label" "$@" 2>"$t/err.txt"
}

# ---------------------------------------------------------------------------
herdr_suite_finish() {
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
}
