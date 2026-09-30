#!/usr/bin/env bash
# =============================================================================
# Regression tests for dial.sh — the one-invocation dial orchestrator.
#
# Everything external is stubbed on PATH (cmux, claude, dirmap, and — for the
# replay round-trip — ps), and every run gets its own $HOME so the sessions
# registry, identity cache and dial history land in a scratch tree instead of
# the user's. The one thing that cannot be redirected by env is
# /tmp/claude-session-<pid> (session-fingerprint.sh hardcodes it), so the fake
# ancestry uses a pid above the OS maximum and the file is cleaned up.
#
# Poison stubs sit at the FRONT of PATH for the whole file: a test that forgets
# its own stub fails loudly here instead of launching a real cmux pane or a real
# `claude` (which is exactly what happened once in cmux-call-async_test.sh).
#
# PATH stubs are not enough on their own any more: every cmux delivery is a
# terminal.paste written straight to cmux's control socket, which no PATH entry
# can intercept. So each scratch env also gets its own stub socket server
# ($CMUX_SOCKET_PATH), and the default one is POISONED — it answers ok:false and
# records a violation, so an unstubbed socket call fails the suite instead of
# reaching the developer's own live cmux.
#
# This file is the shared harness for the dial_wrapper-*_test.sh shards. SOURCE
# it, don't execute it: it sets up the poison PATH and sockets, the stub
# factories and the pass/fail counters, and dial_wrapper_finish runs the
# poison check, prints the result and exits.
# =============================================================================
# Keep standalone runs under the system temp directory while honoring the runner.
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT=${TMP_ROOT%/}
export TMP_ROOT
PASS=0
FAIL=0
FAILED_CASES=()

HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIAL="$HOTLINE_DIR/skills/dial/scripts/dial.sh"

# Each shard sets its own FAKE_CLAUDE_PID (99000N, above any real pid) before sourcing:
# sibling shards run concurrently and the /tmp/claude-session-<pid> path is hardcoded.
: "${FAKE_CLAUDE_PID:?set a shard-unique FAKE_CLAUDE_PID before sourcing this lib}"
STRAY_SESSION_CACHE="/tmp/claude-session-${FAKE_CLAUDE_PID}"

# The suite itself usually runs INSIDE a Claude Code session, which exports
# $CLAUDE_CODE_SESSION_ID into every subprocess. session-init.sh answers from it
# in one call ("native"), so the legacy fingerprint tests below would never see
# their own plant/discover round-trip. Prefix those invocations with this to
# strip the inherited identity — the same reason the fake `ps` exists at all.
# ($CODEX_THREAD_ID is stripped defensively; it is the next rung down.)
STRIP_NATIVE_ID=(env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID)

POISON_BIN="$(mktemp -d)"
POISON_LOG="$POISON_BIN/violations"
for _poison in cmux claude dirmap; do
  cat > "$POISON_BIN/$_poison" <<POISON
#!/usr/bin/env bash
echo "$_poison \$*" >> "$POISON_LOG"
echo "TEST BUG: reached the real $_poison — this invocation is missing its PATH stub" >&2
exit 127
POISON
  chmod +x "$POISON_BIN/$_poison"
done
PATH="$POISON_BIN:$PATH"

# Launch scripts and call dirs the launchers create live outside our scratch
# tree; collect and remove them at the end.
LEAKED=()
trap 'socket_stub_cleanup; rm -rf "$POISON_BIN" "$STRAY_SESSION_CACHE" ${LEAKED[@]+"${LEAKED[@]}"}' EXIT

# --- control-socket stubs ----------------------------------------------------
# The stub server and the python3 argv shim come from tests/lib/socket-stub-harness.sh,
# shared with cmux-reuse-surface_test.sh. They were duplicated in both suites
# before, which is how one copy learns about a new stub option and the other keeps
# passing against a stale idea of the code.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PYTHON3="$(command -v python3)"
if [[ -z "$REAL_PYTHON3" ]]; then
  echo "dial.sh wrapper: SKIP — python3 not available (the control-socket helper needs it)"
  exit 0
fi
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
SOCKROOT="$(mktemp -d)"
LEAKED+=("$SOCKROOT")
socket_stub_write_responses "$SOCKROOT/responses"
SOCK_OK_RESPONSES="$SOCKROOT/responses/ok.json"
SOCK_NO_PASTE_RESPONSES="$SOCKROOT/responses/no-paste.json"

start_socket_stub() { socket_stub_start "$@"; }

POISON_SOCK="$(start_socket_stub "$SOCKROOT/poison")"
: > "$SOCKROOT/poison/requests.log"

# The working socket every cmux case inherits. One server for the whole file
# rather than one per scratch env: the request log and the echo file are shared,
# and assertions look at the LAST terminal.paste, which is the one the case under
# test just made.
# The echo file being SUITE-WIDE is deliberate, and it is also what blocks a
# size-based `[Pasted text +N lines]` collapse in make_cmux below: truncated once
# here, appended to by every case. Any per-size rule needs per-paste records in
# lib/socket-stub.py first — see claude-plugins-7u9g before restructuring this.
SOCK_ECHO_FILE="$SOCKROOT/typed.txt"
: > "$SOCK_ECHO_FILE"
OK_SOCK="$(start_socket_stub "$SOCKROOT/ok" "$SOCK_OK_RESPONSES" "$SOCK_ECHO_FILE")"
OK_REQUESTS="$SOCKROOT/ok/requests.log"
: > "$OK_REQUESTS"
# A socket that accepts the paste but echoes nothing back to the screen: the
# model of a paste whose bytes never arrived.
NOECHO_SOCK="$(start_socket_stub "$SOCKROOT/noecho" "$SOCK_OK_RESPONSES")"
# A socket that refuses the paste for the STALE surface and accepts it for its
# replacement. This is how a case makes reuse fail at DELIVERY — leaving the old
# surface idle and clean, so superseded-surface cleanup is then in play — without
# also breaking delivery into the fresh surface the call falls back to.
STALE_SURFACE="aaaa0000-1111-4111-8111-111111111111"
REJECT_STALE_SOCK="$(start_socket_stub "$SOCKROOT/reject-stale" "$SOCK_OK_RESPONSES" \
  "$SOCK_ECHO_FILE" "$STALE_SURFACE")"
# A cmux with no terminal.paste at all.
NO_PASTE_SOCK="$(start_socket_stub "$SOCKROOT/nopaste" "$SOCK_NO_PASTE_RESPONSES")"

export CMUX_SOCKET_PATH="$OK_SOCK"
export SOCK_ECHO_FILE

# The params of the LAST terminal.paste request, decoded.
last_paste() {  # last_paste [field]  (field defaults to the pasted text)
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
# The params of the Nth terminal.paste request (1-based), decoded. First contact
# for a slash command with a body is delivered as TWO pastes — the invocation line
# (nth 1) then the work-order body (nth 2) — so a caller needs to reach either.
nth_paste() {  # nth_paste <n> [field]  (field defaults to the pasted text)
  local n="$1" field="${2:-text}"
  grep -F '"terminal.paste"' "$OK_REQUESTS" 2>/dev/null | sed -n "${n}p" \
    | "$REAL_PYTHON3" -c '
import json,sys
line = sys.stdin.read().strip()
if not line: sys.exit(0)
if line.startswith("_cmux_capability_v1 "):
    line = line.split(" ", 2)[2]
print(json.loads(line)["params"].get(sys.argv[1], ""), end="")
' "$field" 2>/dev/null
}
paste_count() { grep -cF '"terminal.paste"' "$OK_REQUESTS" 2>/dev/null || true; }
capability_count() { grep -cF '"system.capabilities"' "$OK_REQUESTS" 2>/dev/null || true; }
# Keep the confirmation polls short: the transcript tier legitimately misses in
# this suite (no callee is writing one), and the screen tier answers immediately.
export HOTLINE_PASTE_CONFIRM_TRIES=2
export HOTLINE_PASTE_CONFIRM_SLEEP=0.05
export HOTLINE_PASTE_BOX_TIMEOUT=3
# The cmux stub's `send` never echoes surface-ready.sh's probe back, so every
# detached or window placement times that wait out — non-fatally, by design — and
# no case asserts on the probe. 1s keeps that path instead of paying the shipped
# 8s on every such case (claude-plugins-bfbh).
export HOTLINE_SURFACE_READY_TIMEOUT=1

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}

check() {  # check <label> <condition-result-rc> <diagnostic>
  if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

# --- stub factories ----------------------------------------------------------

# One cmux fake for every path we exercise. Behavior is driven by files in
# $CMUX_FAKE_STATE so a test can shape the screen the REPL "shows".
make_cmux() {
  mkdir -p "$1"
  cat > "$1/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
echo "$*" >> "$ST/cmux_calls"
case "$1" in
  ping)          exit "${CMUX_PING_RC:-0}" ;;
  # Both branches must end on an explicit exit 0: a trailing conditional would
  # otherwise become the stub's exit status, and a "failed" read-screen reads as
  # a dead surface.
  # Whatever the socket stub echoed shows up on the screen ABOVE the input box, as
  # a pasted-and-submitted payload does in a real REPL: claude echoes the turn into
  # its transcript and redraws the box UNDERNEATH it. That order is what delivery
  # confirmation reads (the nonce has to be findable OUTSIDE the box), and it is
  # also the only order the box gates can be tested against — claude draws its box
  # at the bottom with a rule and a hint line under it, never with a screenful of
  # transcript below it, so echoing after screen.txt modelled a screen that cannot
  # exist and pushed the box out of every bottom-of-screen window.
  #
  # WHAT THIS ECHO STILL DOES NOT MODEL, and what it would take (claude-plugins-7u9g):
  # a real Claude Code renders a submitted paste over ~800 chars or 3 lines as a
  # one-line `[Pasted text +N lines]`, so the raw echo below overstates how much of
  # the payload is on screen — it leaves the nonce in the transcript, where a large
  # paste never leaves it. cmux-paste-slash-split_test.sh models the collapse; this
  # suite cannot, for two reasons that have to be fixed together:
  #   • THE ECHO FILE IS SUITE-WIDE. It is truncated once, at setup (see
  #     SOCK_ECHO_FILE above), and every case's pastes append to it — so the
  #     "screen" here is the concatenation of every payload the whole file has
  #     pasted so far, and any size-based rule fires from the second case onward.
  #     Confirmation survives that only because it greps for a per-call nonce.
  #   • THE COLLAPSE IS PER PASTE, not per screen. First contact delivers a slash
  #     command as TWO pastes (the invocation line verbatim, the body collapsed —
  #     claude-plugins-pmgb), and the invocation line is where the nonce lives. A
  #     rule applied to the concatenated file hides that nonce, which no real REPL
  #     does: measured here, 30 cases go red for exactly that fixture reason.
  #   So the faithful fix is per-paste records (lib/socket-stub.py writing a
  #   separator between pastes) plus per-record collapse in this stub, in
  #   cmux-call_test.sh's four stubs, and in slash-split's — one change across
  #   three suites, not a tweak here.
  # Pointing a case at a socket stub started WITHOUT --echo-file models a paste
  # whose bytes never arrived.
  read-screen)   if [[ -n "${SOCK_ECHO_FILE:-}" && -f "$SOCK_ECHO_FILE" ]]; then
                   cat "$SOCK_ECHO_FILE"  # tripwire: claude-plugins-7u9g
                 fi
                 cat "$ST/screen.txt" 2>/dev/null
                 exit 0 ;;
  send)          echo "$*" >> "$ST/send_calls"; exit 0 ;;
  send-key)      echo "$*" >> "$ST/sendkey_calls" ;;
  new-workspace) echo "OK workspace:123" ;;
  # Both the paste and superseded-surface cleanup resolve a surface's workspace
  # and UUID from the tree, via --id-format both. workspace:123 is the detached
  # placement's own tab (what new-workspace above just returned), so a detached
  # first contact can find the surface to paste into.
  tree)          jq -nc '{windows:[{workspaces:[
                   {id:"WORKSPACE-UUID-1",ref:"workspace:5",
                    panes:[{surfaces:[
                     {id:"aaaa0000-1111-4111-8111-111111111111",ref:"surface:1"},
                     {id:"SURFACE-UUID-OLD",ref:"surface:2"},
                     {id:"SURFACE-UUID-777",ref:"surface:777"}]}]},
                   {id:"WORKSPACE-UUID-DETACHED",ref:"workspace:123",
                    panes:[{selected_surface_id:"SURFACE-UUID-DETACHED",
                            surfaces:[{id:"SURFACE-UUID-DETACHED",ref:"surface:900"}]}]}]}]}' ;;
  close-surface) echo "$*" >> "$ST/close_calls"; echo "OK" ;;
  *)             exit 0 ;;
esac
EOF
  chmod +x "$1/cmux"
}

# Stands in for cmux-cli's open-side-surface.sh. Records its own argv when
# $SIDE_OPENER_LOG is set, and reflects --title back as title_status/surface_title
# exactly as the real opener does — hotline passes none, and §15 asserts that
# absence against this log, so the stub has to be able to report one.
make_side_opener() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
[[ -n "${SIDE_OPENER_LOG:-}" ]] && printf '%s\n' "$*" >> "$SIDE_OPENER_LOG"
TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in --title) TITLE="${2:-}"; shift 2 ;; *) shift ;; esac
done
jq -nc --arg t "$TITLE" --arg st "${SIDE_OPENER_TITLE_STATUS:-}" \
  '{surface_ref:"surface:777", surface_id:"SURFACE-UUID-777",
    pane_ref:"pane:55", pane_id:"PANE-UUID-55", workspace_ref:"workspace:5",
    mode:"new-surface", ready:"ready",
    surface_title: (if $t == "" then null else $t end),
    title_status: (if $st != "" then $st elif $t == "" then "unset" else "applied" end)}'
EOF
  chmod +x "$1"
}

# `claude -p --output-format stream-json` shape, enough for
# headless-call-async.sh to lift a session id and a result out of.
make_claude() {
  mkdir -p "$1"
  cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
SID="${FAKE_CLAUDE_SESSION_ID:-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee}"
[[ -n "${FAKE_CLAUDE_STDIN_LOG:-}" ]] && cat > "$FAKE_CLAUDE_STDIN_LOG"
printf '{"type":"system","session_id":"%s"}\n' "$SID"
printf '{"type":"result","session_id":"%s","result":"ok","num_turns":1}\n' "$SID"
EOF
  chmod +x "$1/claude"
}

# dirmap reading the scratch $HOME/.dirmap.json, so fuzzy resolution is
# deterministic instead of depending on the user's real map.
make_dirmap() {
  mkdir -p "$1"
  cat > "$1/dirmap" <<'EOF'
#!/usr/bin/env bash
MAP="$HOME/.dirmap.json"
case "$1" in
  get)  jq -er --arg id "${2:-}" '.[$id] // empty' "$MAP" 2>/dev/null || exit 1 ;;
  list) cat "$MAP" ;;
  *)    exit 1 ;;
esac
EOF
  chmod +x "$1/dirmap"
}

# Fake process ancestry whose claude process is $FAKE_CLAUDE_PID, so the
# fingerprint/pending key is STABLE across invocations — which is the whole
# point of keying pending state on the claude pid rather than the shell's.
make_ps() {
  mkdir -p "$1"
  cat > "$1/ps" <<'EOF'
#!/usr/bin/env bash
FAKE="${FAKE_CLAUDE_PID:?}"
mode=""; pid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) mode="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$mode" in
  comm=) [[ "$pid" == "$FAKE" ]] && echo "claude" || echo "bash" ;;
  ppid=) [[ "$pid" == "$FAKE" ]] && echo "1" || echo "$FAKE" ;;
esac
EOF
  chmod +x "$1/ps"
}

# --- scratch workspace -------------------------------------------------------

new_env() {   # echoes a fresh scratch root with bin/, home/, target/, work/
  local t
  t=$(mktemp -d "$TMP_ROOT"/hotline-dial-test-XXXXXX)
  mkdir -p "$t/bin" "$t/home" "$t/target" "$t/work" "$t/pending" "$t/empty"
  # A booted REPL: the banner (wait-for-session's signal A) AND a drawn input box
  # (signal C, and what cmux-paste.sh waits for before pasting — a paste into a
  # shell that has not yet exec'd claude is lost silently).
  printf 'Claude Code v2.1.221\n%s\n\xe2\x9d\xaf\xc2\xa0\n%s\n' \
    "────────────────────" "────────────────────" > "$t/screen.txt"
  echo "$t"
}

note_leak() { LEAKED+=("$@"); }

# printf %q quoting turns every space in the prompt into `\ `. Drop the
# backslashes so assertions can match the prompt as the receiver will read it.
unquoted() { tr -d '\\'; }

# Records the call_dir + launch script from a dial payload for cleanup, and
# echoes the launch script's contents so tests can assert on the claude argv.
launch_script_of() {  # launch_script_of <call_dir>
  local cd="$1" ls=""
  [[ -s "$cd/launch_script.txt" ]] && ls=$(cat "$cd/launch_script.txt")
  [[ -n "$ls" && -f "$ls" ]] && { note_leak "$ls"; cat "$ls"; }
}

# ===========================================================================
dial_wrapper_finish() {
  if [[ -s "$POISON_LOG" ]]; then
    fail "no test reaches the real cmux, claude, or dirmap" "$(cat "$POISON_LOG")"
  else
    pass "no test reaches the real cmux, claude, or dirmap"
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
}
