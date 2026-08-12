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
STUB_PIDS=()
stop_stubs() {
  local p
  for p in ${STUB_PIDS[@]+"${STUB_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
}
trap 'stop_stubs; rm -rf "$POISON_BIN" "$STRAY_SESSION_CACHE" ${LEAKED[@]+"${LEAKED[@]}"}' EXIT

# --- control-socket stubs ----------------------------------------------------
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET_STUB="$TESTS_DIR/lib/socket-stub.py"
REAL_PYTHON3="$(command -v python3)"
if [[ -z "$REAL_PYTHON3" ]]; then
  echo "dial.sh wrapper: SKIP — python3 not available (the control-socket helper needs it)"
  exit 0
fi
SOCKROOT="$(mktemp -d)"
LEAKED+=("$SOCKROOT")

# The canned answers a working cmux gives. system.capabilities must advertise
# terminal.paste under result.METHODS — result.capabilities is a different list
# of *.v1 feature tokens and never contains it, so a preflight reading the wrong
# one would degrade every call on a cmux that supports the verb perfectly well.
SOCK_OK_RESPONSES="$SOCKROOT/ok.json"
cat > "$SOCK_OK_RESPONSES" <<'JSON'
{"system.capabilities": {"ok": true, "result": {
   "methods": ["system.capabilities", "terminal.paste", "workspace.close"],
   "capabilities": ["terminal.bytes.v1", "events.v1"]}},
 "terminal.paste": {"ok": true, "result": {"submitted": true}},
 "_default": {"ok": true, "result": {}}}
JSON
# A cmux too old to offer the verb: the preflight must catch this and say so.
SOCK_NO_PASTE_RESPONSES="$SOCKROOT/no-paste.json"
cat > "$SOCK_NO_PASTE_RESPONSES" <<'JSON'
{"system.capabilities": {"ok": true, "result": {
   "methods": ["system.capabilities", "workspace.close"],
   "capabilities": ["terminal.bytes.v1"]}},
 "_default": {"ok": true, "result": {}}}
JSON

# start_socket_stub <dir> [responses] [echo-file] — echoes the socket path.
# Blocks on the stub's own READY line rather than sleeping and hoping.
start_socket_stub() {
  local dir="$1" responses="${2:-}" echo_file="${3:-}" reject="${4:-}" sock args=() i
  mkdir -p "$dir"
  sock="$dir/cmux.sock"
  args=(--socket "$sock" --requests "$dir/requests.log")
  if [[ -n "$responses" ]]; then
    args+=(--responses "$responses")
  else
    args+=(--poison --violations "$POISON_LOG")
  fi
  [[ -n "$echo_file" ]] && args+=(--echo-file "$echo_file")
  [[ -n "$reject" ]] && args+=(--reject-surface "$reject")
  "$REAL_PYTHON3" "$SOCKET_STUB" "${args[@]}" > "$dir/stub.out" 2>"$dir/stub.err" &
  STUB_PIDS+=($!)
  for i in $(seq 1 60); do
    grep -q READY "$dir/stub.out" 2>/dev/null && break
    sleep 0.05
  done
  printf '%s' "$sock"
}

POISON_SOCK="$(start_socket_stub "$SOCKROOT/poison")"
: > "$SOCKROOT/poison/requests.log"

# The working socket every cmux case inherits. One server for the whole file
# rather than one per scratch env: the request log and the echo file are shared,
# and assertions look at the LAST terminal.paste, which is the one the case under
# test just made.
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
  read-screen)   cat "$ST/screen.txt" 2>/dev/null
                 # Whatever the socket stub echoed shows up on the screen, as a
                 # pasted payload would in a real REPL: that is how delivery
                 # confirmation sees its nonce. Pointing a case at a socket stub
                 # started WITHOUT --echo-file models a paste whose bytes never
                 # arrived.
                 if [[ -n "${SOCK_ECHO_FILE:-}" && -f "$SOCK_ECHO_FILE" ]]; then
                   cat "$SOCK_ECHO_FILE"
                 fi
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

# First contact is PASTED, not launched. The ringing invocation and its tags are
# asserted against the terminal.paste request, and the launch script is asserted
# to be free of them: the prompt on claude's argv is the claude-plugins-86ka leak,
# and it is what scope B of the paste rework exists to close.
pasted="$(last_paste)"
grep -q '/hotline:hotline-ringing' <<<"$pasted" \
  && grep -qF '[MODE: work_order]' <<<"$pasted" \
  && grep -qF '[SESSION: caller-1111]' <<<"$pasted" \
  && grep -qF '[CALLER: ' <<<"$pasted" \
  && grep -qF 'run the suite' <<<"$pasted"
check "first contact PASTES the ringing command with MODE/CALLER/SESSION tags" $? \
  "pasted=$pasted"

[[ "$pasted" == '/hotline:hotline-ringing [CALL_ID: '* ]]
check "the nonce follows the slash command (a leading header would break parsing)" $? \
  "pasted=$pasted"

launch_plain=$(unquoted <<<"$launch")
if grep -qF 'run the suite' <<<"$launch_plain" \
   || grep -q 'hotline-ringing' <<<"$launch_plain"; then
  fail "the prompt never reaches claude's argv" "launch=$launch"
else
  pass "the prompt never reaches claude's argv"
fi

[[ "$(last_paste surface_id)" == "SURFACE-UUID-777" \
   && "$(last_paste workspace_id)" == "WORKSPACE-UUID-1" \
   && "$(last_paste submit_key)" == "return" ]]
check "the paste is addressed to the new surface by UUID, submit_key=return" $? \
  "surface=$(last_paste surface_id) ws=$(last_paste workspace_id) key=$(last_paste submit_key)"

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
printf 'some earlier output\n\xe2\x9d\xaf \n' > "$t/screen.txt"
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
printf 'some earlier output\n\xe2\x9d\xaf \nClaude Code v2.1.221\n' > "$t/screen.txt"
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
printf 'some earlier output\n\xe2\x9d\xaf \nClaude Code v2.1.221\n' > "$t/screen.txt"
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
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-1] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf \n' \
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
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-3] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf \n' \
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
printf '\xe2\x9d\xaf [CALL_ID: nonce-prev-2] the previous follow-up\n\nClaude Code v2.1.221\n\xe2\x9d\xaf \n' \
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
# 7. Conference mode early-returns after cmux-call.sh — no boot/response wait.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
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

unquoted < "$conf_launch" 2>/dev/null | grep -qF '[MODE: conference_call]' 
check "conference first contact carries the conference_call MODE tag" $? \
  "launch=$(cat "$conf_launch" 2>/dev/null)"

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
printf 'some earlier conference output\n\xe2\x9d\xaf \n' > "$t/screen.txt"
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
printf 'Request interrupted by user\nWhat should Claude do instead?\n' > "$t/screen.txt"
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

jq -e '.fallbacks | index("terminal-paste-unavailable→headless")' <<<"$out" >/dev/null 2>&1
check "a cmux without terminal.paste records the capability miss as a fallback" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

[[ "$(jq -r .status <<<"$out")" == "connected" && "$(jq -r .transport <<<"$out")" == "headless" ]]
check "…and the call still completes, over the headless transport" $? "out=$out"

[[ ! -s "$SOCKROOT/nopaste/requests.log" ]] || \
  ! grep -qF '"terminal.paste"' "$SOCKROOT/nopaste/requests.log"
check "…and no paste is attempted against a cmux that cannot do it" $? \
  "$(cat "$SOCKROOT/nopaste/requests.log" 2>/dev/null)"

# ===========================================================================
# The prompt is written to a 0600 temp file and cleaned up, even when the caller
# passed --prompt. Handing the launchers a file is what keeps the payload out of
# every argv downstream (claude-plugins-86ka); leaving the file behind would
# undo the point of the 0600.
# ===========================================================================
t=$(new_env); note_leak "$t"
make_cmux "$t/bin"; make_side_opener "$t/side.sh"
mkdir -p "$t/bin2"
# A python3 shim in front of the socket helper: records its argv and the mode of
# the file it was handed, so "the payload travels as an owner-only path, never as
# an argument" is asserted rather than assumed.
cat > "$t/bin2/python3" <<SHIM
#!/usr/bin/env bash
printf '%q ' "\$@" >> "$t/python-argv.log"; printf '\n' >> "$t/python-argv.log"
for _a in "\$@"; do
  if [[ -n "\${_want:-}" ]]; then
    printf 'PAYLOAD_MODE %s\n' \
      "\$(stat -f '%Lp' "\$_a" 2>/dev/null || stat -c '%a' "\$_a" 2>/dev/null)" >> "$t/python-argv.log"
    _want=""
  fi
  [[ "\$_a" == "--payload-file" ]] && _want=1
done
exec "$REAL_PYTHON3" "\$@"
SHIM
chmod +x "$t/bin2/python3"
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
