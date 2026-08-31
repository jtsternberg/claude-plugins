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
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAL="$HOTLINE_DIR/skills/dial/scripts/dial.sh"

FAKE_CLAUDE_PID=990001          # above any real pid, so it can never collide
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
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
                   cat "$SOCK_ECHO_FILE"
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

# Stands in for cmux-cli's open-side-surface.sh.
make_side_opener() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"surface_ref":"surface:777","surface_id":"SURFACE-UUID-777","pane_ref":"pane:55","pane_id":"PANE-UUID-55","workspace_ref":"workspace:5","mode":"new-surface","ready":"ready"}'
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
  t=$(mktemp -d /tmp/hotline-dial-test-XXXXXX)
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

echo "dial.sh wrapper regression:"

# ===========================================================================
# 1. Cached identity, first contact, cmux side-by-side — one invocation.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# The OK socket log accumulates across cases; reset it so this case's paste count
# and paste indices (nth_paste) are its own.
: > "$OK_REQUESTS"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-1111" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "run the suite" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" ]]
check "cached identity connects in ONE invocation (exit 0, status=connected)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .transport <<<"$out")" == "cmux" \
   && "$(jq -r .placement <<<"$out")" == "side" \
   && "$(jq -r .first_contact <<<"$out")" == "true" \
   && "$(jq -r .caller_session_id <<<"$out")" == "caller-1111" \
   && "$(jq -r .workspace <<<"$out")" == "$(cd "$t/target" && pwd -P)" ]]
check "payload reports transport/placement/first_contact/caller/workspace" $? "out=$out"

[[ "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-777" ]]
check "payload carries the stable surface handle" $? "out=$out"

[[ "$(jq -r '.remote_session_id' <<<"$out")" =~ ^[0-9a-f]{8}- ]]
check "payload carries the callee session id from wait-for-session" $? "out=$out"

[[ "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "clean cmux path records no fallbacks" $? "out=$out"

[[ "$(jq -r .awaiting_response <<<"$out")" == "true" ]]
check "async modes flag awaiting_response=true (wait-for-response is a separate step)" $? "out=$out"

# First contact is PASTED, not launched, and in TWO pastes: the slash invocation +
# its protocol tags ride paste 1 ALONE so it renders verbatim and the command
# parses; the work-order body rides paste 2, whose placeholder CC expands back
# inside the command args on submit (claude-plugins-pmgb). A single paste of the
# whole thing is the regression — a body over CC's ~800-char / 3-line threshold
# collapses the invocation's leading `/` and the ringing protocol never loads.
# The launch script is asserted free of the prompt: the prompt on claude's argv is
# the claude-plugins-86ka leak that scope B of the paste rework exists to close.
invite="$(nth_paste 1)"
body="$(nth_paste 2)"
[[ "$(paste_count)" -eq 2 ]] \
  && grep -q '/hotline:hotline-ringing' <<<"$invite" \
  && grep -qF '[MODE: work_order]' <<<"$invite" \
  && grep -qF '[SESSION: caller-1111]' <<<"$invite" \
  && grep -qF '[CALLER: ' <<<"$invite" \
  && grep -qF 'run the suite' <<<"$body"
check "first contact PASTES the ringing command + tags on paste 1, body on paste 2" $? \
  "invite=$invite body=$body count=$(paste_count)"

[[ "$invite" == '/hotline:hotline-ringing [CALL_ID: '* ]]
check "the nonce follows the slash command (a leading header would break parsing)" $? \
  "invite=$invite"

# The invocation line carries no work-order body, so nothing can push it past CC's
# collapse threshold and take the leading `/` down with it.
[[ "$invite" != *$'\n'* && "$invite" != *'run the suite'* ]]
check "the invocation paste is one line with no body glued on" $? \
  "invite=$invite"

launch_plain=$(unquoted <<<"$launch")
if grep -qF 'run the suite' <<<"$launch_plain" \
   || grep -q 'hotline-ringing' <<<"$launch_plain"; then
  fail "the prompt never reaches claude's argv" "launch=$launch"
else
  pass "the prompt never reaches claude's argv"
fi

[[ "$(nth_paste 1 surface_id)" == "SURFACE-UUID-777" \
   && "$(nth_paste 1 workspace_id)" == "WORKSPACE-UUID-1" \
   && "$(nth_paste 1 submit_key)" == "none" \
   && "$(nth_paste 2 submit_key)" == "none" ]]
check "both pastes go to the new surface by UUID, submit_key=none" $? \
  "surf=$(nth_paste 1 surface_id) ws=$(nth_paste 1 workspace_id) k1=$(nth_paste 1 submit_key) k2=$(nth_paste 2 submit_key)"

# The two-paste sequence is submitted by a real Enter key event, outside any paste.
grep -qiE '(^| )(enter|return)( |$)' "$t/sendkey_calls" 2>/dev/null
check "first contact submits with a separate Enter keystroke" $? \
  "sendkey_calls=$(cat "$t/sendkey_calls" 2>/dev/null)"

[[ "$(capability_count)" -ge 1 ]]
check "the dial preflights terminal.paste over the socket" $? \
  "capability calls: $(capability_count)"

[[ ! -f "$call_dir/pending_paste.md" ]]
check "pending_paste.md is removed once the prompt has landed" $? \
  "still present in $call_dir"

grep -q -- '--resume' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "fresh first contact passes neither --resume nor --fork-session" "launch=$launch"
else
  pass "fresh first contact passes neither --resume nor --fork-session"
fi

# The registry write is script-level (wait-for-session → register-call), so the
# wrapper must not need to do it — assert it happened.
[[ -s "$t/home/.agents-hotline/sessions/caller-1111.json" ]]
check "first contact is registered in the sessions registry" $? \
  "$(ls -R "$t/home/.agents-hotline" 2>/dev/null)"

# ===========================================================================
# 2. Replay round-trip: plant → re-run the identical command → connected.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_claude "$t/bin"; make_ps "$t/bin"
mkdir -p "$t/home/.claude/projects/testproj"
rm -f "$STRAY_SESSION_CACHE"

DIAL_ARGS=(--target "$t/target" --mode quick --headless
           --prompt "what branch are you on?" --boot-timeout 8)
run_replay() {
  ( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
      FAKE_CLAUDE_PID="$FAKE_CLAUDE_PID" HOTLINE_PENDING_DIR="$t/pending" \
      FAKE_CLAUDE_SESSION_ID="cccccccc-dddd-4eee-8fff-000000000000" \
      "${STRIP_NATIVE_ID[@]}" bash "$DIAL" "${DIAL_ARGS[@]}" 2>>"$t/err.txt" )
}

out1=$(run_replay); rc1=$?
fp=$(jq -r '.fingerprint // empty' <<<"$out1" 2>/dev/null)

[[ "$rc1" -eq 2 && "$(jq -r .status <<<"$out1")" == "replay" ]]
check "identity cache miss emits status=replay and exits 2" $? "rc=$rc1 out=$out1"

[[ "$fp" == SESSION_FINGERPRINT_* ]]
check "replay payload carries the fingerprint (so it reaches the transcript)" $? "out=$out1"

[[ -s "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" ]]
check "pending state is persisted keyed by the claude pid" $? \
  "$(ls "$t/pending" 2>/dev/null)"

[[ "$(sed -n '1p' "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" 2>/dev/null)" == "$fp" ]]
check "pending file holds the same fingerprint that was emitted" $? \
  "$(cat "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" 2>/dev/null)"

# Simulate the harness flushing that output into the caller's transcript.
CALLER_SID="12345678-1234-4123-8123-123456789abc"
printf '{"type":"user","cwd":"%s","content":"%s"}\n' "$t/work" "$fp" \
  > "$t/home/.claude/projects/testproj/${CALLER_SID}.jsonl"

out2=$(run_replay); rc2=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out2" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc2" -eq 0 && "$(jq -r .status <<<"$out2")" == "connected" ]]
check "the identical re-run discovers the session and completes the call" $? \
  "rc=$rc2 out=$out2 stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .caller_session_id <<<"$out2")" == "$CALLER_SID" ]]
check "re-run adopts the discovered caller session id" $? "out=$out2"

[[ ! -e "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}" ]]
check "pending state is cleared once discovery succeeds" $? \
  "$(ls "$t/pending" 2>/dev/null)"

[[ "$(jq -r .remote_session_id <<<"$out2")" == "cccccccc-dddd-4eee-8fff-000000000000" ]]
check "headless transport reports the callee session id from the stream" $? "out=$out2"

# A third run must NOT replay again — the discovered id is cached now.
out3=$(run_replay); rc3=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out3" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
[[ "$rc3" -eq 0 && "$(jq -r .status <<<"$out3")" == "connected" ]]
check "identity stays cached — a later dial never replays again" $? "rc=$rc3 out=$out3"
rm -f "$STRAY_SESSION_CACHE"

# ===========================================================================
# 3. Disambiguation surfaces as status=needs_disambiguation + candidates.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_dirmap "$t/bin"
mkdir -p "$t/home/alpha" "$t/home/beta"
jq -n --arg a "$t/home/alpha" --arg b "$t/home/beta" \
  '{alpha:$a, beta:$b}' > "$t/home/.dirmap.json"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-3333" \
  HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "the mystery workspace" --mode quick \
    --prompt "hello?" 2>"$t/err.txt")
rc=$?

[[ "$rc" -eq 3 && "$(jq -r .status <<<"$out")" == "needs_disambiguation" ]]
check "ambiguous reference exits 3 with status=needs_disambiguation" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r '.candidates | length' <<<"$out")" -eq 2 ]]
check "candidates from resolve-workspace.sh are surfaced verbatim" $? "out=$out"

[[ "$(jq -r '.reference' <<<"$out")" == "the mystery workspace" ]]
check "the user's exact reference is echoed back for the ask" $? "out=$out"

[[ "$(jq -r '.candidates[0] | has("path") and has("id")' <<<"$out")" == "true" ]]
check "each candidate keeps its id and path" $? "out=$out"

# ===========================================================================
# 4. Headless fold-in: cmux up, cmux-cli missing → re-fire, record a fallback.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-4444" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/nope.sh" HOTLINE_PLUGINS_DIR="$t/empty" \
  HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="44444444-4444-4444-8444-444444444444" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "fold me in" --boot-timeout 8 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .transport <<<"$out")" == "headless" ]]
check "cmux-cli-missing folds into headless inside the wrapper (still connected)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

jq -e '.fallbacks | index("cmux-cli-missing→headless")' <<<"$out" >/dev/null 2>&1
check "the fold-in is recorded in fallbacks, not bounced to the model" $? "out=$out"

[[ "$(jq -r .placement <<<"$out")" == "none" ]]
check "headless transport reports placement=none" $? "out=$out"

[[ "$(jq -r .remote_session_id <<<"$out")" == "44444444-4444-4444-8444-444444444444" ]]
check "the re-fired headless call is the one we wait on" $? "out=$out"

# ===========================================================================
# 5. Follow-up reuses the surface the session already lives in.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"
# An idle claude REPL: an empty input box, no spinner, no interrupt prompt.
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-5555" --session "55555555-5555-4555-8555-555555555555" \
  --mode work_order --surface "SURFACE-UUID-777"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-5555" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "one more thing" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "follow-up connects with first_contact=false" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

pasted="$(last_paste)"
[[ "$pasted" == *'one more thing' && "$(last_paste surface_id)" == "SURFACE-UUID-777" ]]
check "the follow-up message is pasted into the existing surface" $? \
  "pasted=$pasted surface=$(last_paste surface_id)"

if grep -q 'hotline:hotline-ringing' <<<"$pasted"; then
  fail "follow-ups never re-wrap with the ringing command" "pasted=$pasted"
else
  pass "follow-ups never re-wrap with the ringing command"
fi

# The nonce leads its own line for a follow-up: nothing here is a slash command,
# and a header on its own line cannot be broken across a rendered wrap.
[[ "$pasted" == '[CALL_ID: '*']'$'\n''one more thing' ]]
check "the follow-up carries the nonce on a line of its own" $? "pasted=$(printf '%q' "$pasted")"

# No send-key, and no `cmux send` of the payload: submit_key does the submitting,
# and the payload never touches the transport that used to lose bytes from it.
if [[ -s "$t/sendkey_calls" ]]; then
  fail "reuse needs no separate send-key Enter" "sendkey_calls=$(cat "$t/sendkey_calls")"
else
  pass "reuse needs no separate send-key Enter"
fi
if grep -q 'one more thing' "$t/send_calls" 2>/dev/null; then
  fail "the payload never goes out through cmux send" "send_calls=$(cat "$t/send_calls")"
else
  pass "the payload never goes out through cmux send"
fi

# Reuse must not open a surface, so no launch script is ever written.
[[ -n "$call_dir" && ! -f "$call_dir/launch_script.txt" ]]
check "reuse opens no new surface (no launch script)" $? "call_dir=$call_dir"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-5555.json" 2>/dev/null)" == "2" ]]
check "reuse bumps the cache's exchange_count" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-5555.json" 2>/dev/null)"

[[ "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "a successful reuse records no fallbacks" $? "out=$out"

# HOW it landed travels with the connection. `confirmed` names the tier that proved
# delivery (transcript is definitive, screen is inference) and `retried_enter` says
# whether the paste's own submit key had to be rescued by a corrective Enter — a run
# of those is the submit_key race resurfacing (claude-plugins-fkgv, -y4rl), which is
# invisible to the caller if the wrapper drops the fields cmux-paste.sh reports.
jq -e '(.confirmed | type == "string") and (.confirmed | length > 0)
       and (.retried_enter | type == "boolean")' <<<"$out" >/dev/null 2>&1
check "a successful reuse reports .confirmed and .retried_enter" $? "out=$out"

# ===========================================================================
# 6. Follow-up whose surface refuses the message → resume into a fresh surface.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# One screen has to serve three readers here: cmux-reuse-surface.sh sees the
# post-interrupt prompt and declines; wait-for-session.sh (polling the NEW surface
# through the same stub) needs the REPL banner to confirm boot; and cmux-paste.sh
# needs a drawn input box before it will paste into that new surface.
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6666" --session "66666666-6666-4666-8666-666666666666" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6666" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "please continue" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "a refused reuse still completes via the fresh-surface path" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

jq -e '.fallbacks | map(startswith("surface-reuse→fresh")) | any' <<<"$out" >/dev/null 2>&1
check "the refusal (and its reason) is recorded in fallbacks" $? "out=$out"

grep -q -- '--resume 66666666-6666-4666-8666-666666666666' <<<"$launch"
check "resume-fresh resumes OUR cached session" $? "launch=$launch"

grep -q -- '--fork-session' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "resume-fresh never forks our own session" "launch=$launch"
else
  pass "resume-fresh never forks our own session"
fi

grep -q -- '--session-id' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "plain resume omits --session-id (claude rejects the combination)" "launch=$launch"
else
  pass "plain resume omits --session-id (claude rejects the combination)"
fi

[[ "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-777" ]]
check "the new surface handle replaces the dead one in the payload" $? "out=$out"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' \
      "$t/home/.agents-hotline/sessions/caller-6666.json" 2>/dev/null)" == "SURFACE-UUID-777" ]]
check "the cache is self-healed to the new surface for the next follow-up" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-6666.json" 2>/dev/null)"

# A multi-line follow-up REUSES the live surface (claude-plugins-i8fb). It used
# to skip reuse outright, which is what stacked a new pane on every substantive
# work-order follow-up — and then, briefly, to reuse it by writing the payload to
# a sidecar file and typing a pointer. Now the payload itself is pasted, whole.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
# A work-order-sized payload with a sentinel at the very END: a delivery that
# truncates or splits the body loses the tail first, so the sentinel arriving is
# what proves the whole thing went in one piece.
{ for i in $(seq 1 12); do echo "follow-up detail line $i of the work order"; done
  echo 'TAIL-SENTINEL-9Q'; } > "$t/msg.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-7777" --session "77777777-7777-4777-8777-777777777777" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-7777" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt-file "$t/msg.txt" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .surface_ref <<<"$out")" == "SURFACE-UUID-OLD" \
   && -n "$call_dir" && ! -f "$call_dir/launch_script.txt" ]]
check "a multi-line follow-up reuses the live surface, opening no second one" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# The WHOLE payload, in ONE request, tail included.
[[ "$(last_paste)" == *"$(cat "$t/msg.txt")" ]]
check "the multi-line payload is pasted byte-identical, tail sentinel and all" $? \
  "pasted=$(printf '%q' "$(last_paste)")"

# No sidecar, and nothing for the callee to go read outside its own workspace.
[[ ! -f "$call_dir/message.md" ]]
check "no message.md sidecar is written" $? "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

[[ ! -f "$call_dir/payload.txt" ]]
check "the payload vehicle is cleaned out of the call dir" $? \
  "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

if grep -q 'TAIL-SENTINEL-9Q' "$t/send_calls" 2>/dev/null; then
  fail "the payload never crosses cmux send" "send_calls=$(cat "$t/send_calls")"
else
  pass "the payload never crosses cmux send"
fi

[[ "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "reusing for a multi-line follow-up records no fallback (nothing degraded)" $? \
  "out=$out"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-7777.json")" == "2" \
   && "$(jq -r --arg t "$target_real" '.connections[$t].last_call_id' \
      "$t/home/.agents-hotline/sessions/caller-7777.json")" == "$(jq -r .call_id <<<"$out")" ]]
check "the reuse bumps the cache and records this exchange's nonce" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-7777.json" 2>/dev/null)"

# ===========================================================================
# 6b. Every bail out of the reuse guard records a fallback (claude-plugins-6nbr).
#
# The add_fallback for a refusal used to live inside the block the guard skipped,
# so a follow-up that opened a second pane reported fallbacks:[] — identical to a
# clean first-contact dial, with nothing to explain the new tab.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\nClaude Code v2.1.221\n' > "$t/screen.txt"
# A cached session with NO surface: what a headless or detached first contact
# leaves behind, and what --clear-surface leaves after a degraded follow-up.
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6b" --session "6b6b6b6b-6b6b-4b6b-8b6b-6b6b6b6b6b6b" \
  --mode work_order
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6b" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "single line, but nowhere to type it" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | index("surface-reuse-skipped(no-cached-surface)")' <<<"$out" >/dev/null 2>&1
check "a follow-up with no cached surface records the skip" $? "out=$out"

[[ "$(jq -r .first_contact <<<"$out")" == "false" && "$(jq -r .status <<<"$out")" == "connected" ]]
check "…and still completes as a follow-up via the fresh path" $? "out=$out"

# ===========================================================================
# 6c. A follow-up that ends with NO surface CLEARS the cached one
#     (claude-plugins-2caw).
#
# Two ways to get there: the cmux→headless fold-in, and side placement degrading
# to detached. Both used to leave the previous surface_ref in the cache, so the
# next follow-up passed the reuse guard and typed into a surface this session had
# already left — the message landing in a REPL nobody was reading.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
# The reuse guard runs BEFORE the transport fold-in, so a usable cached surface
# would be reused and the headless path never reached. Stage a REPL that refuses
# the follow-up (post-interrupt state) so the call falls through to the transport
# decision, which is what this case is about.
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6c" --session "6c6c6c6c-6c6c-4c6c-8c6c-6c6c6c6c6c6c" \
  --mode work_order --surface "SURFACE-UUID-STALE"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6c" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/nope.sh" HOTLINE_PLUGINS_DIR="$t/empty" \
  HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="6c6c6c6c-6c6c-4c6c-8c6c-6c6c6c6c6c6c" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "fold me into headless" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
target_real=$(cd "$t/target" && pwd -P)
cache_6c="$t/home/.agents-hotline/sessions/caller-6c.json"

[[ "$(jq -r .transport <<<"$out")" == "headless" ]]
check "the headless fold-in still applies on a follow-up" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r --arg t "$target_real" '.connections[$t] | has("surface_ref")' "$cache_6c")" == "false" ]]
check "a headless follow-up CLEARS the stale surface_ref" $? "$(cat "$cache_6c" 2>/dev/null)"

# Side placement degrading to detached: open-side-surface exits 2 with the
# identify diagnostic cmux-call-async.sh keys on, so no surface_ref.txt is ever
# written and the call lands in its own workspace instead.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
# Same two-readers screen as case 6: cmux-reuse-surface.sh sees the post-interrupt
# prompt and declines (so the call reaches the placement decision), while
# wait-for-session.sh needs the REPL banner to confirm the detached boot.
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
cat > "$t/side-degrade.sh" <<'EOF'
#!/usr/bin/env bash
echo "open-side-surface: could not resolve caller pane from identify" >&2
exit 2
EOF
chmod +x "$t/side-degrade.sh"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6d" --session "6d6d6d6d-6d6d-4d6d-8d6d-6d6d6d6d6d6d" \
  --mode work_order --surface "SURFACE-UUID-STALE"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6d" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side-degrade.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "degrade me to detached" --boot-timeout 8 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null
target_real=$(cd "$t/target" && pwd -P)
cache_6d="$t/home/.agents-hotline/sessions/caller-6d.json"

[[ "$(jq -r .placement <<<"$out")" == "detached" ]] \
  && jq -e '.fallbacks | index("surface-context→detached")' <<<"$out" >/dev/null 2>&1
check "side placement degrades to detached and says so" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r --arg t "$target_real" '.connections[$t] | has("surface_ref")' "$cache_6d")" == "false" ]]
check "a degraded-to-detached follow-up CLEARS the stale surface_ref" $? \
  "$(cat "$cache_6d" 2>/dev/null)"

# ===========================================================================
# 6e. A follow-up that opens a NEW surface closes the one it superseded
#     (claude-plugins-n7xo).
#
# `claude --resume` in the new surface takes the session over, so the old surface
# holds a REPL nobody will speak to again. Nothing used to close it, and a long
# exchange accumulated one dead tab per turn.
#
# Reuse has to fail while the old surface stays readable and idle, which is
# exactly the lossy-send case: the nudge goes out, its nonce never appears, reuse
# falls back — and the old REPL is still sitting there idle.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# The prior exchange's nonce is in scrollback (proof of identity), the REPL is
# idle, and the banner lets wait-for-session confirm the replacement booted.
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-1] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6e" --session "6e6e6e6e-6e6e-4e6e-8e6e-6e6e6e6e6e6e" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111" --call-id "nonce-prev-1"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" CMUX_SOCKET_PATH="$REJECT_STALE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-6e" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | index("surface-cleanup→closed(aaaa0000-1111-4111-8111-111111111111)")' <<<"$out" >/dev/null 2>&1
check "the superseded surface is closed, and the close is reported" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

grep -q 'close-surface --workspace WORKSPACE-UUID-1 --surface aaaa0000-1111-4111-8111-111111111111' \
  "$t/close_calls" 2>/dev/null
check "the close targets the OLD surface by handle, with its workspace" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

! grep -q 'surface SURFACE-UUID-777' "$t/close_calls" 2>/dev/null
check "the replacement surface is never the one closed" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# Without a recorded nonce there is nothing tying the handle to our exchange, so
# cleanup must refuse — and say so rather than closing on a weaker signal.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6f" --session "6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f6f6f" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6f" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | map(startswith("surface-cleanup-skipped")) | any' <<<"$out" >/dev/null 2>&1
check "a cleanup that cannot prove identity records a skip" $? "out=$out"

[[ ! -s "$t/close_calls" ]]
check "…and closes nothing" $? "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# A cache written by an older plugin version holds a POSITIONAL surface:N ref.
# Closing on that is unsafe in a way the nonce cannot rescue: the replacement
# resumed the same session, so its scrollback replays the same nonce, and a
# repositioned ref could name the replacement rather than the superseded surface.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-3] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6h" --session "6h6h6h6h-6h6h-4h6h-8h6h-6h6h6h6h6h6h" \
  --mode work_order --surface "surface:211" --call-id "nonce-prev-3"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" CMUX_SOCKET_PATH="$REJECT_STALE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-6h" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | map(contains("positional-ref-unsafe")) | any' <<<"$out" >/dev/null 2>&1
check "a positional cached ref is never closed, and says why" $? "out=$out"

[[ ! -s "$t/close_calls" ]]
check "…and nothing is closed for it" $? "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# The opt-out reaches the cleanup through dial.sh, not just the script.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-2] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6g" --session "6g6g6g6g-6g6g-4g6g-8g6g-6g6g6g6g6g6g" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111" --call-id "nonce-prev-2"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" CMUX_SOCKET_PATH="$REJECT_STALE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-6g" HOTLINE_CLOSE_SUPERSEDED=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "carry on please" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

jq -e '.fallbacks | index("surface-cleanup-skipped(disabled)")' <<<"$out" >/dev/null 2>&1
check "HOTLINE_CLOSE_SUPERSEDED=0 reaches cleanup through dial.sh" $? "out=$out"

[[ ! -s "$t/close_calls" ]]
check "…and nothing is closed when it is off" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# ===========================================================================
# 6j. --fresh ignores the cached session AND its surface (claude-plugins-osrz).
#
# Without it, forcing a new callee session meant hand-deleting the caller→target
# entry from the sessions registry — and an orchestration run that skipped that
# step got its "reviewer" as the implementer resumed. The flag has to do three
# things at once: not resume, leave the cache pointing at the NEW session (or the
# next dial routes back to the abandoned one), and hand the surface it walked away
# from to the same cleanup a follow-up's superseded surface gets.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
: > "$OK_REQUESTS"
# The prior exchange's nonce is in scrollback (cleanup's identity proof), the REPL
# is idle, and the banner + input box let the REPLACEMENT surface confirm boot and
# take the paste through the same stub screen.
printf '\xe2\x9d\xaf [CALL_ID: nonce-fresh-1] the previous exchange\n\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-6j" --session "6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a" \
  --mode work_order --surface "aaaa0000-1111-4111-8111-111111111111" --call-id "nonce-fresh-1"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6j" HOTLINE_CLEANUP_SETTLE=0 \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --fresh \
    --prompt "review the branch with no prior context" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch=$(launch_script_of "$call_dir")
cache_6j="$t/home/.agents-hotline/sessions/caller-6j.json"
target_real=$(cd "$t/target" && pwd -P)

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "true" ]]
check "--fresh connects and reports first_contact=true despite a cached session" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

grep -q -- '--resume' <<<"$launch"
if [[ $? -eq 0 ]]; then
  fail "--fresh resumes nothing — the whole point of the flag" "launch=$launch"
else
  pass "--fresh resumes nothing — the whole point of the flag"
fi

jq -e '.fallbacks | index("session-cache→fresh(6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a)")' \
  <<<"$out" >/dev/null 2>&1
check "the ignored session is named in fallbacks, not silently dropped" $? "out=$out"

# A brand-new session needs the ringing protocol loaded, which is the first-contact
# wrapper — a --fresh dial that sent the raw message would reach a callee that
# never loaded the skill.
grep -q '/hotline:hotline-ringing' <<<"$(nth_paste 1)"
check "--fresh delivers the first-contact ringing invocation" $? "paste1=$(nth_paste 1)"

new_session=$(jq -r .remote_session_id <<<"$out")
[[ -n "$new_session" && "$new_session" != "6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a" ]]
check "the callee session is a new one, not the cached one" $? "out=$out"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].session_id' "$cache_6j")" == "$new_session" ]]
check "the cache is rewritten to the NEW session (the next dial must not route back)" $? \
  "$(cat "$cache_6j" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' "$cache_6j")" == "SURFACE-UUID-777" ]]
check "…and to the new surface" $? "$(cat "$cache_6j" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' "$cache_6j")" == "1" ]]
check "…as a fresh entry, not a bumped one" $? "$(cat "$cache_6j" 2>/dev/null)"

jq -e '.fallbacks | index("surface-cleanup→closed(aaaa0000-1111-4111-8111-111111111111)")' \
  <<<"$out" >/dev/null 2>&1
check "the surface --fresh walked away from goes through the normal cleanup" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

grep -q 'close-surface --workspace WORKSPACE-UUID-1 --surface aaaa0000-1111-4111-8111-111111111111' \
  "$t/close_calls" 2>/dev/null
check "the close targets the abandoned surface by handle, with its workspace" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

! grep -q 'surface SURFACE-UUID-777' "$t/close_calls" 2>/dev/null
check "the new surface is never the one closed" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# 6j-b. --fresh with nothing cached is an ordinary first contact — no fallback,
# because nothing was worked around.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-6j-b" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order --fresh \
    --prompt "nothing to ignore here" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
launch_script_of "$call_dir" >/dev/null

[[ "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r '.fallbacks | length' <<<"$out")" -eq 0 ]]
check "--fresh with no cached session records no fallback" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ ! -s "$t/close_calls" ]]
check "…and closes nothing (there was no surface to supersede)" $? \
  "close_calls=$(cat "$t/close_calls" 2>/dev/null)"

# 6j-c. --fresh and --resume are opposite instructions about which session to talk
# to. Resolving it either way silently hands the caller the one they did not ask
# for, so it is an args error — the same stage every other flag contradiction uses.
t=$(new_env); note_leak "$t"
for order in "--fresh --resume 12345678-1234-4234-8234-123456789abc" \
             "--resume 12345678-1234-4234-8234-123456789abc --fresh"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-6j-c" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 10 bash "$DIAL" --target "$t/target" --mode quick --prompt x \
        $order 2>/dev/null)
  rc=$?
  [[ "$rc" -eq 1 && "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]] \
    && grep -q -- '--fresh' <<<"$o"
  check "--fresh with --resume is an args error ($order)" $? "rc=$rc out=$o"
done

# ===========================================================================
# 7. Conference mode early-returns after cmux-call.sh — no boot/response wait.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# Reset the shared OK socket log so nth_paste indexes this case's pastes.
: > "$OK_REQUESTS"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-8888" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode conference \
    --prompt "let us pair on this" 2>"$t/err.txt")
rc=$?
# cmux-call.sh's launch script self-deletes only when executed; ours never is.
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && note_leak "$conf_launch"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .mode <<<"$out")" == "conference_call" ]]
check "conference mode connects through cmux-call.sh" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .awaiting_response <<<"$out")" == "false" ]]
check "conference mode reports awaiting_response=false (early return)" $? "out=$out"

[[ "$(jq -r 'has("call_dir")' <<<"$out")" == "false" ]]
check "conference mode emits no call_dir (nothing to poll)" $? "out=$out"

[[ "$(jq -r .remote_session_id <<<"$out")" =~ ^[0-9a-f]{8}- ]]
check "conference mode reports the callee session id" $? "out=$out"

# The prompt is PASTED, not launched: conference was the last hotline path putting a
# payload on claude's argv (claude-plugins-92s5), and its launch script must now be
# free of it.
# First contact splits into two pastes; the MODE tag rides paste 1 (the invocation).
[[ "$(nth_paste 1)" == *'[MODE: conference_call]'* ]]
check "conference first contact PASTES the conference_call MODE tag on paste 1" $? \
  "invite=$(nth_paste 1) launch=$(cat "$conf_launch" 2>/dev/null)"

if grep -qF 'MODE: conference_call' "$conf_launch" 2>/dev/null; then
  fail "the conference prompt never reaches claude's argv" "launch=$(cat "$conf_launch")"
else
  pass "the conference prompt never reaches claude's argv"
fi

# cmux-call.sh mints a nonce now — conference calls had none, so the receiver had
# nothing to echo and superseded-surface cleanup could never prove a conference
# surface's identity.
[[ "$(jq -r '.call_id // empty' <<<"$out")" =~ ^[0-9a-f]{16}$ ]]
check "a conference call carries a call_id nonce" $? "out=$out"
[[ "$(nth_paste 1)" == *"$(jq -r '.call_id' <<<"$out")"* ]]
check "…and the nonce is in paste 1, after the slash command" $? \
  "invite=$(nth_paste 1)"

# cmux-call.sh registers the session itself, so the wrapper must not have to.
[[ -s "$t/home/.agents-hotline/sessions/caller-8888.json" ]]
check "conference call is registered by cmux-call.sh" $? \
  "$(ls -R "$t/home/.agents-hotline" 2>/dev/null)"

# ...but cmux-call.sh has no --surface to register, so the wrapper must add it.
# Without this the next conference turn finds no surface_ref, skips the reuse
# guard, and opens a SECOND surface resuming a session whose REPL is still live.
target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' \
      "$t/home/.agents-hotline/sessions/caller-8888.json" 2>/dev/null)" == "SURFACE-UUID-777" ]]
check "conference first contact records surface_ref for the next turn" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-8888.json" 2>/dev/null)"

# ===========================================================================
# 8. Errors carry stage / detail / recovery.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
: > "$t/screen.txt"     # blank: never shows a banner → wait-for-session times out
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-9999" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "never boots" --boot-timeout 1 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir" && launch_script_of "$call_dir" >/dev/null

[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "boot" ]]
check "a REPL that never boots is status=error stage=boot (exit 1)" $? "rc=$rc out=$out"

[[ -n "$(jq -r '.detail // empty' <<<"$out")" \
   && -n "$(jq -r '.recovery // empty' <<<"$out")" ]]
check "boot errors carry both detail and recovery" $? "out=$out"

[[ -n "$(jq -r '.call_dir // empty' <<<"$out")" ]]
check "boot errors keep the call_dir so its diagnostics are readable" $? "out=$out"

t=$(new_env); note_leak "$t"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-aaaa" \
  HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/does-not-exist-anywhere" --mode quick \
    --prompt "hi" 2>"$t/err.txt")
rc=$?
[[ "$rc" -eq 1 && "$(jq -r .stage <<<"$out")" == "resolve" ]]
check "an unresolvable absolute path is status=error stage=resolve" $? "rc=$rc out=$out"

# ===========================================================================
# 9. Output contract: every exit path emits exactly one JSON object.
# ===========================================================================
t=$(new_env); note_leak "$t"
for args in "--mode quick --prompt x" "--target /tmp --prompt x" \
            "--target /tmp --mode quick" "--target /tmp --mode bogus --prompt x" \
            "--target /tmp --mode quick --prompt x --placement window"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-bbbb" \
      HOTLINE_PENDING_DIR="$t/pending" bash "$DIAL" $args 2>/dev/null)
  jq -e 'type == "object" and has("status")' <<<"$o" >/dev/null 2>&1
  check "invalid args ($args) still emit one JSON object with a status" $? "out=$o"
done

# ===========================================================================
# 10. Argument parsing can't hang, and can't silently misread a typo.
# ===========================================================================
# A trailing value flag used to spin the parse loop forever at full CPU with no
# JSON on stdout: `shift 2` with one arg left fails WITHOUT shifting, and there
# is no `set -e` to stop it. `--prompt-file "$VAR"` with an empty VAR reaches it.
t=$(new_env); note_leak "$t"
for flag in --target --mode --prompt-file --prompt --placement --window \
            --tools --resume --caller-session --boot-timeout; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 5 bash "$DIAL" --mode quick --prompt x "$flag" 2>/dev/null)
  rc=$?
  [[ "$rc" -eq 1 && "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]]
  check "trailing bare $flag errors immediately instead of spinning" $? \
    "rc=$rc (124 = still hanging) out=$o"
done

o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    timeout 5 bash "$DIAL" --target /tmp --mode quick --prompt-fil /tmp/x 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]] \
  && grep -q 'prompt-fil' <<<"$o"
check "a misspelled flag errors and names itself (never silently ignored)" $? "out=$o"

o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    timeout 5 bash "$DIAL" --target /tmp --mode quick --prompt x --boot-timeout soon 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]]
check "a non-numeric --boot-timeout is rejected before it reaches arithmetic" $? "out=$o"

# HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE: a missing/unreadable path fails at
# the args stage, before any launch — otherwise it is an opaque cmux boot
# timeout. The error names the variable so the reader knows what to fix.
o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$t/no-such-prompt.txt" \
    timeout 5 bash "$DIAL" --target /tmp --mode quick --prompt x 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "args" ]] \
  && grep -q 'HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE' <<<"$o"
check "an unreadable HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE fails at args and names itself" $? "out=$o"

# ...and a readable one passes validation: the dial gets past args (here it goes
# on to fail at resolve on the bogus target, which proves args did not reject it).
printf 'be terse.' > "$t/real-prompt.txt"
o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
    HOTLINE_PENDING_DIR="$t/pending" \
    HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$t/real-prompt.txt" \
    timeout 10 bash "$DIAL" --target "$t/nope-not-here" --mode quick --prompt x 2>/dev/null)
[[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" != "args" ]]
check "a readable HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE passes the args gate" $? "out=$o"

# --window outranks --placement per SKILL.md, and must do so in EITHER order.
for order in "--placement detached --window winname" "--window winname --placement detached"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 10 bash "$DIAL" --target "$t/nope-not-here" --mode quick --prompt x \
        $order 2>/dev/null)
  # Reaching the resolve stage proves placement validated as `window` (a stray
  # `detached` would too, so pair this with the args-stage check below).
  [[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" == "resolve" ]]
  check "--window is order-independent ($order)" $? "out=$o"
done
# ...and the pairing: an invalid --placement alongside --window is fine, because
# --window replaces it. Order-dependent code would reject one of these two.
for order in "--placement bogus --window winname" "--window winname --placement bogus"; do
  o=$(PATH="$t/bin:$PATH" HOME="$t/home" HOTLINE_CALLER_SESSION_ID="caller-cccc" \
      HOTLINE_PENDING_DIR="$t/pending" \
      timeout 10 bash "$DIAL" --target "$t/nope-not-here" --mode quick --prompt x \
        $order 2>/dev/null)
  [[ "$(jq -r '.stage // empty' <<<"$o" 2>/dev/null)" != "args" ]]
  check "--window overrides an unusable --placement ($order)" $? "out=$o"
done

# ===========================================================================
# 11. Conference follow-ups reuse the live surface instead of stacking one.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'some earlier conference output\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-conf" --session "cfcfcfcf-cfcf-4fcf-8fcf-cfcfcfcfcfcf" \
  --mode conference_call --surface "SURFACE-UUID-777"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-conf" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode conference \
    --prompt "next thought" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$(jq -r .status <<<"$out")" == "connected" \
   && "$(jq -r .first_contact <<<"$out")" == "false" ]]
check "conference follow-up connects with first_contact=false" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(last_paste)" == *'next thought' ]] \
  && ! grep -q 'hotline-cmux-launch' "$t/send_calls" 2>/dev/null
check "conference follow-up is pasted into the live surface, opens no second one" $? \
  "pasted=$(last_paste) send_calls=$(cat "$t/send_calls" 2>/dev/null)"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-conf.json" 2>/dev/null)" == "2" ]]
check "conference follow-up bumps exchange_count" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-conf.json" 2>/dev/null)"

# Refused reuse on a conference call: falls back to cmux-call.sh --resume, and
# the cache still has to move (a raw follow-up carries no tags, so cmux-call.sh
# registers nothing at all on this path).
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# Interrupted (so reuse refuses) but with a drawn box (so the FRESH conference
# surface, read through the same stub, accepts the paste).
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-conf2" --session "c2c2c2c2-c2c2-42c2-82c2-c2c2c2c2c2c2" \
  --mode conference_call --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-conf2" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode conference \
    --prompt "carry on" 2>"$t/err.txt")
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && note_leak "$conf_launch"

[[ "$(jq -r .status <<<"$out")" == "connected" ]] \
  && grep -q -- '--resume c2c2c2c2-c2c2-42c2-82c2-c2c2c2c2c2c2' "$conf_launch" 2>/dev/null
check "a refused conference reuse resumes into a fresh surface" $? \
  "out=$out launch=$(cat "$conf_launch" 2>/dev/null)"

target_real=$(cd "$t/target" && pwd -P)
[[ "$(jq -r --arg t "$target_real" '.connections[$t].exchange_count' \
      "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)" == "2" ]]
check "the conference fresh-surface path still bumps the cache" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)"

[[ "$(jq -r --arg t "$target_real" '.connections[$t].surface_ref' \
      "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)" == "SURFACE-UUID-777" ]]
check "the conference fresh-surface path self-heals surface_ref" $? \
  "$(cat "$t/home/.agents-hotline/sessions/caller-conf2.json" 2>/dev/null)"

# ===========================================================================
# 12. A multi-line refusal reason stays ONE fallbacks entry.
# ===========================================================================
# fb_json serializes one entry per line, so an embedded newline used to split a
# single refusal into several bogus array entries.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# `send` fails with a two-line diagnostic, which lands in the refusal reason.
cat > "$t/bin/cmux" <<'EOF'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
echo "$*" >> "$ST/cmux_calls"
case "$1" in
  ping)        exit 0 ;;
  read-screen) cat "$ST/screen.txt" 2>/dev/null ;;
  send)
    if [[ "$*" == *"--surface SURFACE-UUID-OLD"* ]]; then
      printf 'cmux: send failed
second line of the diagnostic
' >&2
      exit 9
    fi
    echo "$*" >> "$ST/send_calls" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$t/bin/cmux"
printf 'idle
â¯ 
Claude Code v2.1.221
' > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-dddd" --session "dddddddd-dddd-4ddd-8ddd-dddddddddddd" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-dddd" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "reason has newlines" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir" && launch_script_of "$call_dir" >/dev/null

# One entry for the refusal — the point of the case. Superseded-surface cleanup
# legitimately adds a second entry of its own, so count the refusal's entries
# rather than the whole array.
[[ "$(jq -r '[.fallbacks[] | select(startswith("surface-reuse→fresh"))] | length' \
      <<<"$out" 2>/dev/null)" -eq 1 ]]
check "a multi-line refusal reason is one fallbacks entry, not several" $? "out=$out"

jq -e '.fallbacks[0] | startswith("surface-reuse→fresh")' <<<"$out" >/dev/null 2>&1
check "that entry still names the refusal" $? "out=$out"

# ===========================================================================
# 13. Pending identity state: expiry restarts the retry budget.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_claude "$t/bin"; make_ps "$t/bin"
mkdir -p "$t/home/.claude/projects/testproj"
rm -f "$STRAY_SESSION_CACHE"

# An old pending file that already burned the whole budget. It must be discarded
# as a leftover (or a recycled PID) rather than inherited into an error.
printf 'SESSION_FINGERPRINT_STALE-NEVER-PLANTED\n3\n1000000000\n' \
  > "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}"
out=$( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
  FAKE_CLAUDE_PID="$FAKE_CLAUDE_PID" HOTLINE_PENDING_DIR="$t/pending" \
  "${STRIP_NATIVE_ID[@]}" \
  bash "$DIAL" --target "$t/target" --mode quick --headless --prompt "hi" 2>/dev/null )
rc=$?
[[ "$rc" -eq 2 && "$(jq -r .status <<<"$out")" == "replay" \
   && "$(jq -r .attempt <<<"$out")" == "1" ]]
check "an expired pending fingerprint restarts the retry budget at attempt 1" $? \
  "rc=$rc out=$out"

# A FRESH pending file that has already used the budget must still give up,
# rather than replaying forever.
printf 'SESSION_FINGERPRINT_FRESH-BUT-NEVER-PLANTED\n3\n%s\n' "$(date +%s)" \
  > "$t/pending/hotline-pending-${FAKE_CLAUDE_PID}"
out=$( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
  FAKE_CLAUDE_PID="$FAKE_CLAUDE_PID" HOTLINE_PENDING_DIR="$t/pending" \
  "${STRIP_NATIVE_ID[@]}" \
  bash "$DIAL" --target "$t/target" --mode quick --headless --prompt "hi" 2>/dev/null )
rc=$?
[[ "$rc" -eq 1 && "$(jq -r .stage <<<"$out")" == "identity" ]]
check "an exhausted retry budget gives up with an identity error" $? "rc=$rc out=$out"

grep -q 'HOTLINE_CALLER_SESSION_ID' <<<"$out"
check "the identity error names the escape hatch" $? "out=$out"
rm -f "$STRAY_SESSION_CACHE"

# Default pending location must be under ~/.agents-hotline, never /tmp.
grep -q 'HOTLINE_PENDING_DIR:-\$HOME/.agents-hotline/pending' "$DIAL"
check "pending state defaults into ~/.agents-hotline, not /tmp" $? \
  "$(grep -n 'PENDING_DIR=' "$DIAL")"

# ===========================================================================
# 14. Native identity ($CLAUDE_CODE_SESSION_ID) connects in ONE invocation.
# ===========================================================================
# Claude Code >= 2.1.132 exports the session ID into every Bash subprocess, so
# session-init.sh answers "cached"/"native" without the fingerprint dance. No
# fake `ps` is stubbed here on purpose: the native rung must not depend on
# process ancestry at all, so a real `ps` finding no claude has to be harmless.
t=$(new_env); note_leak "$t"
make_claude "$t/bin"
NATIVE_SID="9e1c7a3b-2d4f-4a6b-8c1d-0f2e3a4b5c6d"
out=$( cd "$t/work" && PATH="$t/bin:$PATH" HOME="$t/home" \
  HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" \
  env -u HOTLINE_CALLER_SESSION_ID -u CODEX_THREAD_ID \
      CLAUDE_CODE_SESSION_ID="$NATIVE_SID" \
  bash "$DIAL" --target "$t/target" --mode quick --headless \
    --prompt "who am I talking to?" --boot-timeout 8 2>"$t/err.txt" )
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 0 && "$(jq -r .status <<<"$out")" == "connected" ]]
check "native identity connects in ONE invocation (no replay, exit 0)" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .caller_session_id <<<"$out")" == "$NATIVE_SID" ]]
check "the native session id is adopted verbatim as caller_session_id" $? "out=$out"

[[ "$(jq -r .caller_kind <<<"$out")" == "native" ]]
check "the payload reports caller_kind=native" $? "out=$out"

# Nothing may be persisted for a replay that never has to happen — a pending
# file here would make the NEXT dial try to discover a fingerprint from it.
[[ -z "$(ls -A "$t/pending" 2>/dev/null)" ]]
check "the native path plants no pending fingerprint state" $? \
  "$(ls -A "$t/pending" 2>/dev/null)"

[[ -s "$t/home/.agents-hotline/sessions/${NATIVE_SID}.json" ]]
check "the call is registered under the native caller session id" $? \
  "$(ls -R "$t/home/.agents-hotline" 2>/dev/null)"

# ===========================================================================
# Capability preflight: a cmux with no terminal.paste cannot carry a call.
#
# Every cmux delivery is a terminal.paste now, first contact included, so there is
# no paste-free cmux path left to degrade to. The dial says so and goes headless
# rather than resurrecting the argv launch this rework removed — a silent fallback
# tier that reopened the leak would give back exactly what was paid for.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
FAKE_CLAUDE_SESSION_ID="caaaaaaa-cccc-4ccc-8ccc-cccccccccccc"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$NO_PASTE_SOCK" \
  HOTLINE_CALLER_SESSION_ID="caller-cap" HOTLINE_PENDING_DIR="$t/pending" \
  FAKE_CLAUDE_SESSION_ID="$FAKE_CLAUDE_SESSION_ID" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "no paste available here" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

jq -e '.fallbacks | map(startswith("terminal-paste-unavailable→headless")) | any' <<<"$out" >/dev/null 2>&1
check "a cmux without terminal.paste records the capability miss as a fallback" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .transport <<<"$out")" == "headless" ]]
check "…and the call still completes, over the headless transport" $? "out=$out"

[[ ! -s "$SOCKROOT/nopaste/requests.log" ]] || \
  ! grep -qF '"terminal.paste"' "$SOCKROOT/nopaste/requests.log"
check "…and no paste is attempted against a cmux that cannot do it" $? \
  "$(cat "$SOCKROOT/nopaste/requests.log" 2>/dev/null)"

# ===========================================================================
# A prompt that never lands is stage `deliver` — an ERROR, not a fallback.
#
# The surface is open and its REPL is live, but it was never told anything.
# Reporting "connected" would leave the caller polling for a response to a message
# that does not exist, which is the failure mode the confirmation exists to catch.
# The recovery line must warn against a blind re-dial: the paste can land just
# after the confirmation window, and re-dialling then double-delivers.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$NOECHO_SOCK" SOCK_ECHO_FILE="" \
  HOTLINE_CALLER_SESSION_ID="caller-undelivered" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "this one never lands" --boot-timeout 5 2>"$t/err.txt")
rc=$?
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "deliver" ]]
check "a prompt that cannot be confirmed is an error at stage 'deliver'" $? \
  "rc=$rc out=$out"

grep -qi 'never landed' <<<"$(jq -r '.detail // empty' <<<"$out")"
check "…and the detail says the REPL booted but the prompt never landed" $? "out=$out"

grep -qi 'not silently re-dial' <<<"$(jq -r '.recovery // empty' <<<"$out")"
check "…and the recovery warns against a blind re-dial (double-delivery)" $? "out=$out"

# The prompt stays on disk: it is the only copy, and the caller may want it.
[[ -s "$call_dir/pending_paste.md" ]]
check "…and pending_paste.md is left in place for recovery" $? \
  "call_dir contents: $(ls -A "$call_dir" 2>/dev/null | tr '\n' ' ')"

# ===========================================================================
# The prompt is written to a 0600 temp file and cleaned up, even when the caller
# passed --prompt. Handing the launchers a file is what keeps the payload out of
# every argv downstream (claude-plugins-86ka); leaving the file behind would
# undo the point of the 0600.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# A python3 shim in front of the socket helper: records its argv and the mode of
# the file it was handed, so "the payload travels as an owner-only path, never as
# an argument" is asserted rather than assumed.
write_python3_shim "$t/bin2" "$t/python-argv.log"
PROMPTS_BEFORE=$(ls -d /tmp/hotline-prompt-* 2>/dev/null | wc -l | tr -d ' ')
out=$(PATH="$t/bin2:$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-argv" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "PROMPT-ON-ARGV-SENTINEL" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

grep -q -- '--payload-file' "$t/python-argv.log" 2>/dev/null
check "the socket helper is handed a FILE path, not the payload" $? \
  "$(cat "$t/python-argv.log" 2>/dev/null)"

! grep -q 'PROMPT-ON-ARGV-SENTINEL' "$t/python-argv.log" 2>/dev/null
check "no payload text appears in the helper's argv" $? \
  "$(cat "$t/python-argv.log" 2>/dev/null)"

grep -q 'PAYLOAD_MODE 600' "$t/python-argv.log" 2>/dev/null
check "the file the helper reads is owner-only (0600)" $? \
  "$(grep PAYLOAD_MODE "$t/python-argv.log" 2>/dev/null)"

PROMPTS_AFTER=$(ls -d /tmp/hotline-prompt-* 2>/dev/null | wc -l | tr -d ' ')
[[ "$PROMPTS_AFTER" -le "$PROMPTS_BEFORE" ]]
check "the dial's own prompt temp file does not outlive the dial" $? \
  "before=$PROMPTS_BEFORE after=$PROMPTS_AFTER: $(ls -d /tmp/hotline-prompt-* 2>/dev/null)"

# ===========================================================================
# AN UNCONFIRMED FOLLOW-UP PASTE MUST NOT BECOME A SECOND DELIVERY.
#
# The reuse path pastes, cannot confirm, and used to answer with fallback:fresh —
# which dial.sh serves by opening a NEW surface and re-delivering the SAME prompt
# into a --resume of the SAME session. A payload that actually landed then runs
# TWICE. It reaches this state on its own: a previous exchange leaves
# "[Pasted text +N lines]" in the viewport, the recency baseline correctly discards
# that marker as stale, a new large paste renders as the same placeholder so the
# nonce is not on screen, and the transcript tier misses inside its poll budget.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# A live REPL with a stale placeholder already on screen, and a socket that accepts
# the paste but echoes nothing back — so confirmation has nothing fresh to find.
printf 'some earlier output\n\xe2\x9d\xaf\xc2\xa0\n[Pasted text +40 lines]\nClaude Code v2.1.221\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-dup" --session "dddddddd-dddd-4ddd-8ddd-dddddddddddd" \
  --mode work_order --surface "SURFACE-UUID-777"
printf 'DUPLICATE-DELIVERY-SENTINEL work order body\nsecond line\n' > "$t/msg.txt"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$NOECHO_SOCK" SOCK_ECHO_FILE="" \
  HOTLINE_CALLER_SESSION_ID="caller-dup" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt-file "$t/msg.txt" --boot-timeout 5 2>"$t/err.txt")
rc=$?
DUP_CALL_DIR=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$DUP_CALL_DIR" ]] && note_leak "$DUP_CALL_DIR"

[[ "$rc" -eq 1 && "$(jq -r .status <<<"$out")" == "error" \
   && "$(jq -r .stage <<<"$out")" == "deliver" ]]
check "an unconfirmed follow-up paste is stage 'deliver', not a fresh fallback" $? \
  "rc=$rc out=$out"

# THE POINT: no second surface was opened, so the prompt was not delivered twice.
[[ ! -f "$t/side_log" ]] || [[ -z "$(cat "$t/side_log" 2>/dev/null)" ]]
check "…and NO fresh surface was opened (the payload is not delivered twice)" $? \
  "side_log=$(cat "$t/side_log" 2>/dev/null)"
[[ "$(grep -c 'DUPLICATE-DELIVERY-SENTINEL' "$SOCKROOT/noecho/requests.log" 2>/dev/null || echo 0)" -eq 1 ]]
check "…and the payload crossed the socket exactly ONCE" $? \
  "pastes: $(grep -c 'DUPLICATE-DELIVERY-SENTINEL' "$SOCKROOT/noecho/requests.log" 2>/dev/null || echo 0)"

jq -e '.recovery | test("Do NOT re-dial")' <<<"$out" >/dev/null 2>&1
check "…and the recovery forbids re-dialling rather than suggesting a retry" $? "out=$out"
jq -e '.recovery | test("transcript")' <<<"$out" >/dev/null 2>&1
check "…and points at the callee's transcript as the way to find out what happened" $? "out=$out"
[[ -s "$DUP_CALL_DIR/pending_paste.md" ]]
check "…and the prompt survives in the call dir (it is the only copy)" $? \
  "call dir: $(ls -A "$DUP_CALL_DIR" 2>/dev/null | tr '\n' ' ')"

# The other side of the line: a refusal BEFORE anything was sent still falls back to
# a fresh surface, because the callee received nothing.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
printf 'Request interrupted by user\nWhat should Claude do instead?\nClaude Code v2.1.221\n\xe2\x9d\xaf\xc2\xa0\n' \
  > "$t/screen.txt"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-presend" --session "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-presend" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "refused before anything was sent" --boot-timeout 5 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
[[ "$(jq -r .status <<<"$out")" == "connected" ]] \
  && jq -e '.fallbacks | map(startswith("surface-reuse→fresh")) | any' <<<"$out" >/dev/null 2>&1
check "a pre-send refusal still takes the fresh-surface fallback (nothing was sent)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# ===========================================================================
# NO PAYLOAD ON ANY argv, on ANY transport. The audit, not a spot check.
#
# A `claude` shim records every argv it is ever handed, across all three
# transports: cmux first contact (bare launch + paste), headless (`claude -p`
# reading stdin), and conference (bare launch + paste). Then one assertion: the
# payload sentinel appears in none of them.
#
# This is the claim README.md and dial.sh's own comments make, and before this
# audit two of the three transports quietly contradicted it — headless handed the
# whole prompt to `claude -p "$PROMPT"`, and conference to a launch script's
# positional argument (claude-plugins-86ka, -92s5).
# ===========================================================================
ARGV_SENTINEL="ARGV-AUDIT-SENTINEL-7Q3"
ARGV_LOG=""
argv_audit_env() {   # argv_audit_env <scratch-root> — writes bin/claude, echoes nothing
  local t="$1"
  mkdir -p "$t/bin"
  cat > "$t/bin/claude" <<EOF
#!/usr/bin/env bash
# Record the argv of every claude invocation, whatever the transport.
printf '%q ' "\$@" >> "$ARGV_LOG"; printf '\n' >> "$ARGV_LOG"
SID="\${FAKE_CLAUDE_SESSION_ID:-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee}"
printf '{"type":"system","session_id":"%s"}\n' "\$SID"
printf '{"type":"result","session_id":"%s","result":"ok","num_turns":1}\n' "\$SID"
EOF
  chmod +x "$t/bin/claude"
}

ARGV_LOG=$(mktemp); LEAKED+=("$ARGV_LOG")

# The system-prompt override is a second class of sensitive content that also
# must never ride an argv: it goes through --append-system-prompt-file, so only
# the PATH is on the command line and the CONTENT stays in the file. Seed a file
# whose CONTENT carries its own sentinel and thread it through every audit dial;
# the closing assertion proves that content sentinel never reaches an argv, the
# same guard the payload gets (claude-plugins-86ka).
SP_CONTENT_SENTINEL="SYSPROMPT-CONTENT-SENTINEL-9K2"
SP_FILE=$(mktemp); LEAKED+=("$SP_FILE")
printf '%s\nbe terse.\n' "$SP_CONTENT_SENTINEL" > "$SP_FILE"

# (a) cmux first contact.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"; argv_audit_env "$t"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-audit-1" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$SP_FILE" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "$ARGV_SENTINEL cmux first contact" --boot-timeout 5 2>"$t/err.txt")
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"
# The launch script is what the pane actually runs — collect its text too.
launch_script_of "$call_dir" >> "$ARGV_LOG"
[[ "$(jq -r .status <<<"$out")" == "connected" ]]
check "argv audit: the cmux dial completed" $? "out=$out stderr=$(cat "$t/err.txt")"

# (b) headless.
t=$(new_env); note_leak "$t"
argv_audit_env "$t"; make_ps "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" \
  HOTLINE_CALLER_SESSION_ID="caller-audit-2" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$SP_FILE" \
  bash "$DIAL" --target "$t/target" --mode quick --headless \
    --prompt "$ARGV_SENTINEL headless" --boot-timeout 8 2>"$t/err.txt")
[[ "$(jq -r .status <<<"$out")" == "connected" ]]
check "argv audit: the headless dial completed" $? "out=$out stderr=$(cat "$t/err.txt")"
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" ]] && note_leak "$call_dir"

# (c) conference.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"; argv_audit_env "$t"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-audit-3" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE="$SP_FILE" \
  bash "$DIAL" --target "$t/target" --mode conference \
    --prompt "$ARGV_SENTINEL conference" 2>"$t/err.txt")
[[ "$(jq -r .status <<<"$out")" == "connected" ]]
check "argv audit: the conference dial completed" $? "out=$out stderr=$(cat "$t/err.txt")"
conf_launch=$(grep -oE '/tmp/hotline-cmux-launch-[A-Za-z0-9]+' "$t/send_calls" 2>/dev/null | head -1)
[[ -n "$conf_launch" ]] && { note_leak "$conf_launch"; cat "$conf_launch" >> "$ARGV_LOG" 2>/dev/null; }

# THE ASSERTION.
if grep -qF "$ARGV_SENTINEL" "$ARGV_LOG"; then
  fail "NO transport puts payload text on an argv or in a launch script" \
       "$(grep -F "$ARGV_SENTINEL" "$ARGV_LOG" | head -3)"
else
  pass "NO transport puts payload text on an argv or in a launch script"
fi
# The audit is only meaningful if claude was actually invoked.
[[ -s "$ARGV_LOG" ]]
check "…and the audit actually saw claude invocations (the log is non-empty)" $? \
  "the argv log is empty — the shim never ran, so the assertion above proves nothing"

# System-prompt override: the FLAG threaded (so the absence below is not vacuous),
# but the file's CONTENT never reached an argv — only its path did.
grep -q -- '--append-system-prompt-file' "$ARGV_LOG"
check "…and the system-prompt override threaded as --append-system-prompt-file" $? \
  "no transport carried the flag, so the content-absence check would prove nothing"
if grep -qF "$SP_CONTENT_SENTINEL" "$ARGV_LOG"; then
  fail "NO transport puts system-prompt CONTENT on an argv (only its file path)" \
       "$(grep -F "$SP_CONTENT_SENTINEL" "$ARGV_LOG" | head -3)"
else
  pass "NO transport puts system-prompt CONTENT on an argv (only its file path)"
fi
# `claude -p` with no positional prompt: the prompt arrives on stdin.
grep -qE '^-p ' "$ARGV_LOG" || grep -q "'-p'" "$ARGV_LOG"
check "…and headless invoked 'claude -p' with no positional prompt" $? \
  "$(cat "$ARGV_LOG")"

# ===========================================================================
# The capability preflight distinguishes its failure modes.
#
# The first version funnelled a missing python3, an unreachable socket and a
# genuine capability miss through one `2>/dev/null || true` and reported all three
# as terminal-paste-unavailable — which sends a reader off to upgrade cmux when the
# real problem is a socket nobody is listening on.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  CMUX_SOCKET_PATH="$SOCKROOT/definitely-not-a-socket" \
  HOTLINE_CALLER_SESSION_ID="caller-nosock" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "no socket here" --boot-timeout 5 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out")" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
jq -e '.fallbacks | map(startswith("cmux-socket-unreachable→headless")) | any' <<<"$out" >/dev/null 2>&1
check "an unreachable control socket is reported as such, not as a capability miss" $? \
  "out=$out"
jq -e '.fallbacks | map(test("No such file|refused|socket")) | any' <<<"$out" >/dev/null 2>&1
check "…and the socket's own diagnostic rides along in the reason" $? "out=$out"

# A PATH with no python3 on it at all. Built by symlinking the tools dial.sh needs
# rather than by stripping one entry out of the real PATH: python3 shares /usr/bin
# with most of them, so subtraction is not an option.
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_claude "$t/bin"
mkdir -p "$t/nopy"
for _tool in bash sh env jq sed grep egrep cat cut tr head tail wc ls mktemp rm \
             mkdir dirname basename date realpath awk sort uniq find ps openssl \
             od stat sleep chmod cp mv ln xargs id uname touch printf; do
  _src="$(command -v "$_tool" 2>/dev/null || true)"
  [[ -n "$_src" ]] && ln -sf "$_src" "$t/nopy/$_tool"
done
if [[ -n "$(PATH="$t/nopy" command -v python3 2>/dev/null)" ]]; then
  fail "a missing python3 is reported as a missing python3" \
       "the scratch PATH still resolves python3, so this case proves nothing"
else
out=$(PATH="$t/bin:$t/nopy" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-nopy" HOTLINE_PENDING_DIR="$t/pending" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "no python here" --boot-timeout 5 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
jq -e '.fallbacks | map(startswith("python3-missing→headless")) | any' <<<"$out" >/dev/null 2>&1
check "a missing python3 is reported as a missing python3" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
fi

# ===========================================================================
# Boot signal B needs freshness: a plain resume's transcript ALREADY EXISTS.
#
# `[[ -s $transcript ]]` fired on the first poll for every resume, in the same
# millisecond the launch command was sent — reporting a booted REPL before claude
# had exec'd. Everything downstream then proceeded against a shell, and with
# delivery being a paste that is not a lost message but a work order typed at a
# prompt. Signal B now requires the file to have GROWN.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
# A screen that offers NO boot evidence: no banner, no input box. Only signal B
# could fire here, and it must not.
printf 'some old scrollback with no repl on it\n' > "$t/screen.txt"
RESUME_SID="9a9a9a9a-9b9b-4c9c-8d9d-9e9e9e9e9e9e"
TARGET_REAL=$(cd "$t/target" && pwd -P)
STALE_ENC=$(printf '%s' "$TARGET_REAL" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$t/home/.claude/projects/$STALE_ENC"
# The prior session's transcript: present, non-empty, and untouched from here on.
printf '{"type":"user","message":{"role":"user","content":"a turn from last week"}}\n' \
  > "$t/home/.claude/projects/$STALE_ENC/${RESUME_SID}.jsonl"
HOME="$t/home" bash "$HOTLINE_DIR/skills/dial/scripts/session-cache.sh" set "$t/target" \
  --caller-session "caller-stale" --session "$RESUME_SID" \
  --mode work_order --surface "SURFACE-UUID-OLD"
out=$(PATH="$t/bin:$PATH" HOME="$t/home" CMUX_FAKE_STATE="$t" \
  HOTLINE_CALLER_SESSION_ID="caller-stale" HOTLINE_PENDING_DIR="$t/pending" \
  HOTLINE_OPEN_SIDE_SURFACE="$t/side.sh" \
  bash "$DIAL" --target "$t/target" --mode work_order \
    --prompt "resume into a stale transcript" --boot-timeout 3 2>"$t/err.txt")
[[ -n "$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)" ]] && note_leak "$(jq -r .call_dir <<<"$out")"
[[ "$(jq -r '.status // empty' <<<"$out")" == "error" \
   && "$(jq -r '.stage // empty' <<<"$out")" == "boot" ]]
check "a pre-existing transcript does NOT count as a booted REPL on resume" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# Both directions of signal B, driven straight at wait-for-session.sh — the only
# place the preset session id is an INPUT rather than a random value the launcher
# picked, which is what makes the fresh case deterministic instead of a race.
WFS="$HOTLINE_DIR/skills/dial/scripts/wait-for-session.sh"
signal_b_case() {   # signal_b_case <name> <pre-existing-bytes|""> <grow:yes|no>
  local name="$1" pre="$2" grow="$3"
  local d; d=$(mktemp -d /tmp/hotline-sigb-XXXXXX); note_leak "$d"
  mkdir -p "$d/bin" "$d/home" "$d/call"
  # A screen with NO banner and NO input box: signal B is the only one that can fire.
  cat > "$d/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  read-screen) printf 'old scrollback, no repl here\n' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/bin/cmux"
  local sid="7f7f7f7f-7f7f-4f7f-8f7f-7f7f7f7f7f7f"
  echo "$sid" > "$d/call/session_id_preset.txt"
  echo "SURFACE-SIGB" > "$d/call/surface_ref.txt"
  echo "$d/target" > "$d/call/cwd.txt"
  mkdir -p "$d/target"
  local enc; enc=$(printf '%s' "$d/target" | sed 's|[^a-zA-Z0-9]|-|g')
  mkdir -p "$d/home/.claude/projects/$enc"
  local tr="$d/home/.claude/projects/$enc/${sid}.jsonl"
  [[ -n "$pre" ]] && printf '%s' "$pre" > "$tr"
  if [[ "$grow" == "yes" ]]; then
    ( sleep 1; printf '{"type":"user","message":{"role":"user","content":"fresh turn"}}\n' >> "$tr" ) &
  fi
  SIGB_OUT="$(PATH="$d/bin:$PATH" HOME="$d/home" \
    bash "$WFS" "$d/call" --timeout 6 2>&1)"
  SIGB_RC=$?
  wait 2>/dev/null || true
}

# STALE: the file is already there and never changes. This is every plain resume,
# and a bare existence check fired on the first poll — reporting a booted REPL in
# the same millisecond the launch command was sent.
signal_b_case stale '{"type":"user","message":{"role":"user","content":"a turn from last week"}}
' no
[[ "$SIGB_RC" -ne 0 && "$SIGB_OUT" == *"Timed out"* ]]
check "signal B: a pre-existing, unchanged transcript is NOT a booted REPL" $? \
  "rc=$SIGB_RC out=$SIGB_OUT"

# FRESH-GROWN: the same pre-existing file, appended to mid-wait. A resume that
# really does start writing must still be detected.
signal_b_case grown '{"type":"user","message":{"role":"user","content":"a turn from last week"}}
' yes
[[ "$SIGB_RC" -eq 0 && "$SIGB_OUT" == "7f7f7f7f-7f7f-4f7f-8f7f-7f7f7f7f7f7f" ]]
check "signal B: a transcript that GROWS during the wait is a booted REPL" $? \
  "rc=$SIGB_RC out=$SIGB_OUT"

# FRESH-CREATED: first contact, where the file does not exist at all beforehand.
signal_b_case created "" yes
[[ "$SIGB_RC" -eq 0 ]]
check "signal B: a transcript that APPEARS during the wait is a booted REPL" $? \
  "rc=$SIGB_RC out=$SIGB_OUT"

# ===========================================================================
# ONE definition of the boot budget, and the docs must match it.
#
# The box wait and the boot wait are waiting for the same event, and they lived in
# two places with two values: wait-for-session.sh hardcoded 60 while dial.sh read
# ${BOOT_TIMEOUT:-20} against a variable that is empty unless --boot-timeout was
# passed — so the real default box wait was 20s while README and SKILL.md promised
# 60. A string canary, because what broke was agreement between files.
# ===========================================================================
REPL_STATE="$HOTLINE_DIR/scripts/repl-state.sh"
SHARED_CMUX_DEFAULT=$(sed -n 's/^HOTLINE_BOOT_TIMEOUT_CMUX="\${HOTLINE_BOOT_TIMEOUT_CMUX:-\([0-9]*\)}"/\1/p' "$REPL_STATE")
[[ "$SHARED_CMUX_DEFAULT" == "60" ]]
check "repl-state.sh defines the cmux boot budget as 60" $? "got: '$SHARED_CMUX_DEFAULT'"

grep -q 'TIMEOUT="\$HOTLINE_BOOT_TIMEOUT_CMUX"' "$HOTLINE_DIR/skills/dial/scripts/wait-for-session.sh"
check "wait-for-session.sh takes its default from the shared constant" $? \
  "$(grep -n 'TIMEOUT=6\|TIMEOUT=3\|HOTLINE_BOOT_TIMEOUT' "$HOTLINE_DIR/skills/dial/scripts/wait-for-session.sh")"

grep -q 'PASTE_BOX_TIMEOUT="\${HOTLINE_PASTE_BOX_TIMEOUT:-\${BOOT_TIMEOUT:-\$HOTLINE_BOOT_TIMEOUT_CMUX}}"' "$DIAL"
check "dial.sh resolves the box wait from the same constant, once" $? \
  "$(grep -n 'PASTE_BOX_TIMEOUT=' "$DIAL")"

# No hardcoded 20 left at either delivery site — that was the untrue default.
# Comment lines are excluded: the fix's own comment quotes the old
# ${BOOT_TIMEOUT:-20} to explain what was wrong, and a canary that cannot tell code
# from prose fails on its own explanation.
HARDCODED=$(grep -nE 'BOOT_TIMEOUT:-2?0\}|PASTE_BOX_TIMEOUT:-2?0\}' \
  "$DIAL" "$HOTLINE_DIR/skills/dial/scripts/cmux-call.sh" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [[ -n "$HARDCODED" ]]; then
  fail "no delivery site hardcodes a 20s box wait any more" "$HARDCODED"
else
  pass "no delivery site hardcodes a 20s box wait any more"
fi

# Conference is a delivery site too, and dial.sh never forwarded the budget to it.
grep -q -- '--box-timeout "\$PASTE_BOX_TIMEOUT"' "$DIAL"
check "dial.sh forwards the box wait to the conference launcher" $? \
  "$(grep -n 'CONF_ARGS+=' "$DIAL")"

# And the documented number is the shared one, in both places a reader looks.
for doc in "$HOTLINE_DIR/skills/dial/SKILL.md" "$HOTLINE_DIR/README.md"; do
  rel="${doc#"$HOTLINE_DIR/"}"
  grep -qi 'HOTLINE_PASTE_BOX_TIMEOUT' "$doc"
  check "$rel documents HOTLINE_PASTE_BOX_TIMEOUT" $? "not mentioned"
  grep -qiE 'boot-timeout' "$doc"
  check "$rel ties it to --boot-timeout rather than naming a second number" $? "no --boot-timeout reference"
done

# ===========================================================================
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
