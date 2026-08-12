#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-reuse-surface.sh. Three behaviors are pinned here:
#
#   1. ONE PASTE, WHOLE PAYLOAD — the follow-up is delivered as a single
#      `terminal.paste` over cmux's control socket, carrying the entire payload
#      (with its leading [CALL_ID:] line) in ONE request line. There is no
#      chunking, no size threshold, no sidecar file, and no separate submit key.
#
#   2. NOTHING RIDES ARGV — the payload reaches the socket helper as a file PATH.
#      `cmux rpc` is argv-only, which is why this path exists at all: a work order
#      in an argv is readable by every local user through `ps`
#      (claude-plugins-86ka). The python3 shim below logs the helper's argv, so a
#      payload leaking back into it is a test failure.
#
#   3. DELIVERY IS PROVEN, NOT ASSUMED — ok:true from the socket is an ack. The
#      nonce must show up in the callee's transcript (a user turn OR a
#      queued_command attachment, since a busy REPL writes only the latter) or,
#      failing that, on screen. An unconfirmed paste returns the fresh-surface
#      fallback and leaves no call dir behind.
#
# Plus the pre-send gates, unchanged by the delivery swap: an interrupted REPL,
# a busy REPL with parked text, and a box that will not clear are all refused
# BEFORE anything is sent (claude-plugins-06ws).
#
# TWO STUB LAYERS, because a socket write cannot be intercepted on PATH:
#   • `cmux` and `claude` are PATH stubs (read-screen serves a scripted sequence
#     of fixture screens, tree answers the surface lookup).
#   • $CMUX_SOCKET_PATH points at a python stub server that logs every request
#     line and answers from a canned response file. The default server is
#     POISONED: it answers ok:false and records a violation, so a case that
#     forgets to stage responses fails loudly instead of quietly passing.
# Nothing here touches a real cmux, a real REPL, or the real control socket.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$HOTLINE_DIR/skills/dial/scripts/cmux-reuse-surface.sh"
SOCKET_STUB="$TESTS_DIR/lib/socket-stub.py"
REAL_PYTHON3="$(command -v python3)"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

if [[ -z "$REAL_PYTHON3" ]]; then
  echo "cmux-reuse-surface: SKIP — python3 not available (the control-socket helper needs it)"
  exit 0
fi

# The live input box pads its ❯ glyph with a NO-BREAK SPACE; the transcript
# echoes of prior user turns use a plain space. Both shapes appear in the
# fixtures below so the "which ❯ line is the live box" logic gets exercised.
GLYPH=$'\xe2\x9d\xaf'
NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"

# Stable handles the tree stub knows about.
SURF_UUID="aaaa0000-1111-4111-8111-111111111111"
WS_UUID="bbbb0000-2222-4222-8222-222222222222"
CALLEE_SESSION="cccc0000-3333-4333-8333-333333333333"
CALLEE_CWD="/tmp/callee-ws"

# ---------------------------------------------------------------------------
# Poison stubs. Every case below installs its own `cmux` on PATH; these sit in
# FRONT of the real binaries so a case that forgets one fails loudly here instead
# of reaching the user's actual cmux and opening a live pane. A per-case stub
# prepends ahead of these and still wins. (Same guard as surface-cleanup_test.sh
# and cmux-call-async_test.sh — the latter exists because a missing stub really
# did launch a `claude --resume` pane on every run.)
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

STUBROOT="$(mktemp -d)"

# --- Socket stub plumbing ---------------------------------------------------
STUB_PIDS=()
stop_stubs() {
  local p
  for p in ${STUB_PIDS[@]+"${STUB_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
}
trap 'stop_stubs; rm -rf "$STUBROOT" "$POISON_BIN"' EXIT

# start_socket_stub <dir> [responses-json] — echoes the socket path.
# Blocks until the socket is actually accepting, rather than sleeping and hoping:
# a fixed sleep here is the classic source of a flaky suite.
start_socket_stub() {
  local dir="$1" responses="${2:-}" sock args=() i
  sock="$dir/cmux.sock"
  mkdir -p "$dir"
  args=(--socket "$sock" --requests "$dir/requests.log")
  if [[ -n "$responses" ]]; then
    args+=(--responses "$responses")
  else
    args+=(--poison --violations "$POISON_LOG")
  fi
  "$REAL_PYTHON3" "$SOCKET_STUB" "${args[@]}" > "$dir/stub.out" 2>"$dir/stub.err" &
  STUB_PIDS+=($!)
  for i in $(seq 1 60); do
    grep -q READY "$dir/stub.out" 2>/dev/null && break
    sleep 0.05
  done
  printf '%s' "$sock"
}

# The default socket every case inherits is the poisoned one.
POISON_SOCK="$(start_socket_stub "$STUBROOT/poison-socket")"
: > "$STUBROOT/poison-socket/requests.log"

# Canned responses: a paste the socket accepts, and one it rejects.
OK_RESPONSES="$STUBROOT/ok.json"
cat > "$OK_RESPONSES" <<'JSON'
{"terminal.paste": {"ok": true, "result": {"submitted": true}},
 "_default": {"ok": true, "result": {}}}
JSON
REJECT_RESPONSES="$STUBROOT/reject.json"
cat > "$REJECT_RESPONSES" <<'JSON'
{"terminal.paste": {"ok": false, "error": {"message": "surface is not a terminal"}}}
JSON

# --- Fixture screens -------------------------------------------------------
# Empty box, idle: prior user turn above (plain space), live box below (NBSP).
screen_idle_empty() {
  printf '%s%s Run the earlier thing\n\n%s Baked for 12s\n\n%s\n%s%s\n%s\n' \
    "$GLYPH" " " "✻" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# Same, but the box holds text nobody submitted.
screen_idle_parked() {
  printf '%s%s Run the earlier thing\n\n%s Baked for 12s\n\n%s\n%s%sleftover half-typed thing\n%s\n' \
    "$GLYPH" " " "✻" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# A turn is running: the spinner carries a live elapsed-time parenthetical.
screen_busy_empty() {
  printf '%s%s Run the earlier thing\n\n%s Dilly-dallying… (5s · ↓ 124 tokens · thought for 1s)\n\n%s\n%s%s\n%s\n' \
    "$GLYPH" " " "✶" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
screen_busy_parked() {
  printf '%s%s Run the earlier thing\n\n%s Dilly-dallying… (5s · ↓ 124 tokens · thought for 1s)\n\n%s\n%s%sleftover half-typed thing\n%s\n' \
    "$GLYPH" " " "✶" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# Parked box on a REPL that is producing output (no spinner marker, but the
# screen is not the same from one read to the next).
screen_parked_moving_a() {
  printf '%s%s Run the earlier thing\n\n  reading file 1 of 9\n\n%s\n%s%sleftover half-typed thing\n%s\n' \
    "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
screen_parked_moving_b() {
  printf '%s%s Run the earlier thing\n\n  reading file 4 of 9\n\n%s\n%s%sleftover half-typed thing\n%s\n' \
    "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# The REPL is sitting in its post-interrupt "what now?" state.
screen_interrupted() {
  printf '%s%s Run the earlier thing\n\n  Interrupted · What should Claude do instead?\n\n%s\n%s%s\n%s\n' \
    "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# A never-used REPL shows a greyed placeholder hint inside an EMPTY box.
screen_placeholder() {
  printf '%s\n%s%sTry "how does <filepath> work?"\n%s\n' \
    "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# A large paste collapses to a placeholder — the nonce is genuinely NOT on screen
# even though delivery succeeded.
screen_pasted_placeholder() {
  printf '%s\n%s%s[Pasted text +75 lines]\n%s\n' \
    "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# Queued against a busy REPL. The box renders it like unsent text, so this
# marker is the only screen-side proof.
screen_queued() {
  printf '%s%s Run the earlier thing\n\n%s Working… (5s · ↓ 12 tokens)\n%s\n%s%s\n%s\nPress up to edit queued messages\n' \
    "$GLYPH" " " "✶" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# The user has scrolled up, so read-screen returns a stale viewport and the
# absence of the nonce proves nothing.
screen_scrolled() {
  printf '%s%s Run the earlier thing\n\nJump to bottom (click) ↓\n%s\n%s%s\n%s\n' \
    "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"
}

# --- Stub harness ----------------------------------------------------------
# run_case <name> -- <screen-fn>... -- [extra args to the script under test]
#
# Per-case knobs, set in the environment of the call:
#   CASE_RESPONSES   canned socket responses (default: the poisoned server)
#   CASE_TRANSCRIPT  JSONL body to plant as the callee's transcript
#   CASE_NO_TREE     the tree lookup fails
#   CASE_ORPHAN_TREE the surface is absent from the tree
#   CASE_SURFACE     surface handle to pass (default: the UUID)
#   CASE_TARGET      "" to omit --cwd/--session, forcing the screen fallback
CASEDIR=""
OUT=""
CALLLOG=""
REQLOG=""
PYLOG=""
CASE_CALL_DIR=""
CASE_HAD_PAYLOAD_FILE=false
CASE_HAS_MESSAGE=false

run_case() {
  local name="$1"; shift
  local -a screens=() extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do screens+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  extra=("$@")

  CASEDIR="$STUBROOT/$name"
  mkdir -p "$CASEDIR/screens" "$CASEDIR/bin" "$CASEDIR/home"
  CALLLOG="$CASEDIR/calls.log"
  PYLOG="$CASEDIR/python-argv.log"
  : > "$CALLLOG"; : > "$PYLOG"

  local i=1 fn
  for fn in ${screens[@]+"${screens[@]}"}; do
    "$fn" > "$CASEDIR/screens/$i.txt"
    i=$((i + 1))
  done
  echo $((i - 1)) > "$CASEDIR/screens/count"
  echo 0 > "$CASEDIR/screens/cursor"

  # Socket: a per-case server when responses are staged, else the poisoned one.
  local sock="$POISON_SOCK"
  if [[ -n "${CASE_RESPONSES:-}" ]]; then
    sock="$(start_socket_stub "$CASEDIR/socket" "$CASE_RESPONSES")"
    REQLOG="$CASEDIR/socket/requests.log"
  else
    REQLOG="$STUBROOT/poison-socket/requests.log"
  fi
  local reqbase=0
  [[ -f "$REQLOG" ]] && reqbase=$(wc -l < "$REQLOG" | tr -d ' ')
  echo "$reqbase" > "$CASEDIR/reqbase"

  # The callee's transcript, if this case stages one. HOME is redirected so
  # transcript-path.sh resolves into the sandbox.
  if [[ -n "${CASE_TRANSCRIPT:-}" ]]; then
    local enc
    enc=$(printf '%s' "$CALLEE_CWD" | sed 's|[^a-zA-Z0-9]|-|g')
    mkdir -p "$CASEDIR/home/.claude/projects/$enc"
    printf '%s' "$CASE_TRANSCRIPT" > "$CASEDIR/home/.claude/projects/$enc/${CALLEE_SESSION}.jsonl"
    echo "$CASEDIR/home/.claude/projects/$enc/${CALLEE_SESSION}.jsonl" > "$CASEDIR/transcript_path"
  fi

  cat > "$CASEDIR/bin/cmux" <<'STUB'
#!/usr/bin/env bash
# %q renders every arg shell-quoted on ONE line, so a bundled newline shows up
# as a literal $'\n' token instead of silently wrapping the log.
printf '%q ' "$@" >> "$STUB_CALLLOG"; printf '\n' >> "$STUB_CALLLOG"
case "$1" in
  read-screen)
    n=$(cat "$STUB_SCREENS/count")
    c=$(cat "$STUB_SCREENS/cursor")
    c=$((c + 1)); [[ $c -gt $n ]] && c=$n
    echo "$c" > "$STUB_SCREENS/cursor"
    [[ "$n" -gt 0 ]] && cat "$STUB_SCREENS/$c.txt"
    exit 0
    ;;
  tree)
    [[ -n "${STUB_NO_TREE:-}" ]] && exit 1
    if [[ -n "${STUB_ORPHAN_TREE:-}" ]]; then
      jq -nc '{windows:[{workspaces:[{id:"OTHER-WS",ref:"workspace:9",
        panes:[{surfaces:[{id:"SOMEONE-ELSE",ref:"surface:9"}]}]}]}]}'
    else
      jq -nc --arg s "$STUB_SURF" --arg w "$STUB_WS" \
        '{windows:[{workspaces:[{id:$w,ref:"workspace:1",
          panes:[{surfaces:[{id:$s,ref:"surface:1"}]}]}]}]}'
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$CASEDIR/bin/cmux"

  # python3 shim: records the helper's argv and the MODE of the file it was
  # handed, then delegates. Two things this pins that nothing else can:
  # the payload travels as a path (never as an argument), and that path is
  # owner-only at the moment it is read.
  cat > "$CASEDIR/bin/python3" <<STUB
#!/usr/bin/env bash
printf '%q ' "\$@" >> "$PYLOG"; printf '\n' >> "$PYLOG"
for _a in "\$@"; do
  if [[ -n "\${_want_file:-}" ]]; then
    printf 'PAYLOAD_MODE %s %s\n' \
      "\$(stat -f '%Lp' "\$_a" 2>/dev/null || stat -c '%a' "\$_a" 2>/dev/null)" "\$_a" >> "$PYLOG"
    _want_file=""
  fi
  [[ "\$_a" == "--payload-file" ]] && _want_file=1
done
exec "$REAL_PYTHON3" "\$@"
STUB
  chmod +x "$CASEDIR/bin/python3"

  local -a target=()
  if [[ "${CASE_TARGET-unset}" == "unset" ]]; then
    target=(--cwd "$CALLEE_CWD" --session "$CALLEE_SESSION")
  fi

  OUT="$(STUB_CALLLOG="$CALLLOG" STUB_SCREENS="$CASEDIR/screens" \
    STUB_SURF="$SURF_UUID" STUB_WS="$WS_UUID" \
    STUB_NO_TREE="${CASE_NO_TREE:-}" STUB_ORPHAN_TREE="${CASE_ORPHAN_TREE:-}" \
    CMUX_SOCKET_PATH="$sock" HOME="$CASEDIR/home" \
    HOTLINE_PASTE_CONFIRM_TRIES=3 HOTLINE_PASTE_CONFIRM_SLEEP=0.05 \
    PATH="$CASEDIR/bin:$PATH" bash "$SCRIPT_UNDER_TEST" \
    --surface "${CASE_SURFACE:-$SURF_UUID}" \
    ${target[@]+"${target[@]}"} "${extra[@]}" 2>&1)"

  # Any call_dir the script created is a temp dir. Snapshot what the assertions
  # need out of it BEFORE removing it, so no case has to leave one behind.
  CASE_CALL_DIR=""
  CASE_HAD_PAYLOAD_FILE=false
  CASE_HAS_MESSAGE=false
  local cd_path
  cd_path="$(printf '%s' "$OUT" | sed -n 's/.*"call_dir": *"\([^"]*\)".*/\1/p')"
  if [[ -n "$cd_path" ]]; then
    CASE_CALL_DIR="$cd_path"
    [[ -f "$cd_path/payload.txt" ]] && CASE_HAD_PAYLOAD_FILE=true
    [[ -f "$cd_path/message.md" ]] && CASE_HAS_MESSAGE=true
    [[ -d "$cd_path" ]] && rm -rf "$cd_path"
  fi
  return 0
}

log_view() { cat "$CALLLOG"; }

# Request lines this case produced (the poisoned log is shared, so slice it).
requests() {
  local base; base=$(cat "$CASEDIR/reqbase" 2>/dev/null || echo 0)
  [[ -f "$REQLOG" ]] || return 0
  tail -n "+$((base + 1))" "$REQLOG"
}
request_count() { requests | grep -c . || true; }
# The `text` param of the single terminal.paste request, decoded.
pasted_text() {
  requests | head -1 | "$REAL_PYTHON3" -c '
import json,sys
line = sys.stdin.read().strip()
if line.startswith("_cmux_capability_v1 "):
    line = line.split(" ", 2)[2]
print(json.loads(line)["params"].get("text", ""), end="")
' 2>/dev/null
}
request_field() {  # request_field <jq-ish dotted path under params>
  requests | head -1 | "$REAL_PYTHON3" -c '
import json,sys
line = sys.stdin.read().strip()
if line.startswith("_cmux_capability_v1 "):
    line = line.split(" ", 2)[2]
obj = json.loads(line)
key = sys.argv[1]
print(obj.get(key, obj.get("params", {}).get(key, "")), end="")
' "$1" 2>/dev/null
}
# Count `cmux send` calls whose payload is the raw Ctrl-C byte.
clear_count() { grep -cE "^send .*\\\$'\\\\003'" "$CALLLOG" || true; }
# Index (0-based) of the first Ctrl-C send in the call log, or -1.
clear_index() {
  local i=0 line
  while IFS= read -r line; do
    case "$line" in
      send*\$\'\\003\'*) echo "$i"; return ;;
    esac
    i=$((i + 1))
  done < "$CALLLOG"
  echo -1
}

# A transcript in each landing shape phase-2 found. The queued shape is the one a
# user-turn-only verifier misreads as a lost payload.
transcript_user_turn() {  # transcript_user_turn <nonce>
  printf '{"type":"user","message":{"role":"user","content":"[CALL_ID: %s]\\nthe payload"}}\n' "$1"
}
transcript_queued() {     # transcript_queued <nonce>
  printf '{"type":"attachment","attachment":{"type":"queued_command","prompt":"[CALL_ID: %s]\\nthe payload"}}\n' "$1"
}
nonce_of() { printf '%s' "$OUT" | sed -n 's/.*"call_id": *"\([^"]*\)".*/\1/p'; }
# The nonce is minted inside the script, so a transcript fixture cannot know it
# ahead of time. These cases plant the transcript from the request the stub
# logged, which is exactly what a real callee would have written.
plant_transcript_from_request() {  # plant_transcript_from_request <shape-fn>
  local nonce tp
  nonce=$(pasted_text | sed -n 's/^\[CALL_ID: \([^]]*\)\].*/\1/p' | head -1)
  tp=$(cat "$CASEDIR/transcript_path" 2>/dev/null) || return 1
  [[ -z "$nonce" || -z "$tp" ]] && return 1
  "$1" "$nonce" > "$tp"
}

echo "cmux-reuse-surface"
echo ""
echo "  -- one paste, whole payload --"

# The payload that used to force nudge delivery: multi-line, past the old 800-byte
# inline ceiling, with a $DOLLAR and `backticks` in play.
MULTILINE_MSG=$'Step one: audit the guard at dial.sh line 457 and write down exactly which messages it refuses.\nStep two: fix it, with a $DOLLAR and `backticks` in play, plus a bullet list below.\nStep three: report back.'
BIG_MSG="$MULTILINE_MSG$(printf '\nfiller %.0s' {1..120})"

# A transcript is planted mid-flight by a paste-through socket stub: the first
# read of the transcript comes AFTER the request is logged, so a shape fixture
# written from the request is in place in time.
#
# Simpler and deterministic: give the script a transcript that already contains
# the nonce by letting the screen confirm instead. These first cases assert the
# REQUEST, which needs no confirmation to be true — the script's own output tells
# us which tier confirmed.
CASE_RESPONSES="$OK_RESPONSES" CASE_TRANSCRIPT="" \
  run_case paste_multiline screen_idle_empty screen_pasted_placeholder -- --prompt "$MULTILINE_MSG"
CASE_RESPONSES=""; CASE_TRANSCRIPT=""

[[ "$(request_count)" -eq 1 ]] \
  && pass "exactly ONE socket request carries the whole follow-up" \
  || fail "exactly ONE socket request carries the whole follow-up" "requests: $(request_count)"$'\n'"$(requests)"

[[ "$(request_field method)" == "terminal.paste" ]] \
  && pass "the request method is terminal.paste" \
  || fail "the request method is terminal.paste" "got: $(request_field method)"

[[ "$(pasted_text)" == "[CALL_ID: "*"]"$'\n'"$MULTILINE_MSG" ]] \
  && pass "the pasted text is the [CALL_ID:] line plus the payload, byte for byte" \
  || fail "the pasted text is the [CALL_ID:] line plus the payload, byte for byte" \
          "got: $(printf '%q' "$(pasted_text)")"

[[ "$(pasted_text)" == '[CALL_ID: '* ]] \
  && pass "the nonce LEADS the payload (never split by a line wrap)" \
  || fail "the nonce LEADS the payload (never split by a line wrap)" "got: $(pasted_text)"

# Its own line, not sharing one with the first line of the message: the paste is
# atomic, so the header cannot be welded onto the payload by a wrap.
[[ "$(pasted_text)" == *$']\nStep one'* ]] \
  && pass "the nonce line is terminated before the payload starts" \
  || fail "the nonce line is terminated before the payload starts" "got: $(printf '%q' "$(pasted_text)")"

[[ "$(request_field submit_key)" == "return" ]] \
  && pass "submit_key is 'return'" \
  || fail "submit_key is 'return'" "got: $(request_field submit_key)"

[[ "$(request_field workspace_id)" == "$WS_UUID" && "$(request_field surface_id)" == "$SURF_UUID" ]] \
  && pass "the paste is addressed by workspace and surface UUID, resolved from the tree" \
  || fail "the paste is addressed by workspace and surface UUID, resolved from the tree" \
          "ws=$(request_field workspace_id) surf=$(request_field surface_id)"

[[ "$OUT" == *'"delivery": "paste"'* ]] \
  && pass "the outcome reports delivery=paste" \
  || fail "the outcome reports delivery=paste" "out: $OUT"

$CASE_HAS_MESSAGE \
  && fail "no message.md sidecar is written" "message.md exists" \
  || pass "no message.md sidecar is written"

# The whole point of dropping the archive: nothing durable is written outside the
# call dir any more. HOME is the sandbox for the duration of the case, so anything
# the script wrote under ~/.agents-hotline/ shows up here.
if [[ -n "$(find "$CASEDIR/home" -type f 2>/dev/null | grep -v '/\.claude/' || true)" ]]; then
  fail "no exchange archive is created outside the call dir" \
       "$(find "$CASEDIR/home" -type f | grep -v '/\.claude/')"
else
  pass "no exchange archive is created outside the call dir"
fi

echo ""
echo "  -- nothing rides argv --"

grep -q -- '--payload-file' "$PYLOG" \
  && pass "the socket helper is handed a FILE path, not the payload" \
  || fail "the socket helper is handed a FILE path, not the payload" "$(cat "$PYLOG")"

if grep -qF 'Step one: audit the guard' "$PYLOG"; then
  fail "no payload text appears in the helper's argv" "$(cat "$PYLOG")"
else
  pass "no payload text appears in the helper's argv"
fi

# `cmux send`/`send-key` are gone from the delivery path entirely. A payload on a
# `cmux send` line would be back on argv, and back on a lossy transport.
if grep -E '^send(-key)? ' "$CALLLOG" | grep -qF 'Step one'; then
  fail "the payload never goes out through cmux send" "$(log_view)"
else
  pass "the payload never goes out through cmux send"
fi

if grep -qE '^send-key .*Enter' "$CALLLOG"; then
  fail "no separate send-key Enter is needed" "$(log_view)"
else
  pass "no separate send-key Enter is needed (submit_key does it)"
fi

grep -q "PAYLOAD_MODE 600 " "$PYLOG" \
  && pass "the payload file is owner-only (0600) when the helper reads it" \
  || fail "the payload file is owner-only (0600) when the helper reads it" "$(grep PAYLOAD_MODE "$PYLOG")"

$CASE_HAD_PAYLOAD_FILE \
  && fail "the payload file is removed once delivery is confirmed" "payload.txt survived in $CASE_CALL_DIR" \
  || pass "the payload file is removed once delivery is confirmed"

echo ""
echo "  -- size and escaping are no longer special cases --"

# The old nofy canary. `cmux send` interpreted \n/\r/\t with no escape hatch, so
# the payload had to be split; json.dumps escapes them in-process instead.
CANARY='docs say "\n and \r send Enter" and \t sends Tab, and a bare trailing \'
CASE_RESPONSES="$OK_RESPONSES" run_case paste_canary screen_idle_empty screen_pasted_placeholder -- --prompt "$CANARY"
CASE_RESPONSES=""
[[ "$(pasted_text)" == *"$CANARY" ]] \
  && pass "a payload containing literal \\n \\r \\t arrives byte-for-byte in ONE request" \
  || fail "a payload containing literal \\n \\r \\t arrives byte-for-byte in ONE request" \
          "got: $(printf '%q' "$(pasted_text)")"
[[ "$(request_count)" -eq 1 ]] \
  && pass "…and is not split across several requests" \
  || fail "…and is not split across several requests" "requests: $(request_count)"

# Over the old 800-byte ceiling, and wide characters: both used to change the
# delivery mode. Neither does now.
CASE_RESPONSES="$OK_RESPONSES" run_case paste_big screen_idle_empty screen_pasted_placeholder -- --prompt "$BIG_MSG"
CASE_RESPONSES=""
[[ "$(pasted_text)" == *"$BIG_MSG" && "$(request_count)" -eq 1 ]] \
  && pass "a payload well past the old inline ceiling still goes in ONE paste" \
  || fail "a payload well past the old inline ceiling still goes in ONE paste" \
          "requests=$(request_count) bytes=$(pasted_text | wc -c)"

WIDE_MSG="$(printf '日%.0s' {1..400})"   # 400 chars, 1200 bytes
CASE_RESPONSES="$OK_RESPONSES" run_case paste_wide screen_idle_empty screen_pasted_placeholder -- --prompt "$WIDE_MSG"
CASE_RESPONSES=""
[[ "$(pasted_text)" == *"$WIDE_MSG" ]] \
  && pass "a multibyte payload survives the JSON round trip intact" \
  || fail "a multibyte payload survives the JSON round trip intact" \
          "got ${#WIDE_MSG} chars back as: $(pasted_text | head -c 40)"

# A short single-line follow-up takes the same path — no mode to choose.
CASE_RESPONSES="$OK_RESPONSES" run_case paste_short screen_idle_empty screen_pasted_placeholder -- --prompt "one more thing"
CASE_RESPONSES=""
[[ "$(pasted_text)" == *$'\n''one more thing' && "$OUT" == *'"delivery": "paste"'* ]] \
  && pass "a short single-line follow-up takes the same single path" \
  || fail "a short single-line follow-up takes the same single path" "out: $OUT text: $(printf '%q' "$(pasted_text)")"

# --prompt-file is the same bytes as --prompt.
PF="$STUBROOT/payload.txt"
printf '%s' "$MULTILINE_MSG" > "$PF"
CASE_RESPONSES="$OK_RESPONSES" run_case paste_prompt_file screen_idle_empty screen_pasted_placeholder -- --prompt-file "$PF"
CASE_RESPONSES=""
[[ "$(pasted_text)" == *"$MULTILINE_MSG" ]] \
  && pass "--prompt-file delivers the same bytes as --prompt" \
  || fail "--prompt-file delivers the same bytes as --prompt" "got: $(printf '%q' "$(pasted_text)")"

run_case prompt_file_missing screen_idle_empty -- --prompt-file "$STUBROOT/nope.txt"
[[ "$OUT" == *'"error"'* && "$OUT" == *"does not exist"* ]] \
  && pass "a missing --prompt-file is an error, not an empty message" \
  || fail "a missing --prompt-file is an error, not an empty message" "out: $OUT"

echo ""
echo "  -- delivery is proven, not assumed --"

# PRIMARY TIER: the callee's transcript. Staged from the request the stub logged,
# because the nonce is minted inside the script.
#

# The transcript tier is exercised directly against cmux-paste.sh, where the
# nonce is an input rather than a secret: that is the only way to plant a
# transcript containing it before the poll runs.
PASTE_SCRIPT="$HOTLINE_DIR/skills/dial/scripts/cmux-paste.sh"
# confirm_case <n> <shape-fn|notarget> <screen-fn>
#
# Exercises the confirmation tiers directly against cmux-paste.sh rather than
# through the reuse script, because that is the only place the nonce is an INPUT:
# reuse mints its own, so no fixture written beforehand could contain it.
# "notarget" withholds --cwd/--session, which is what forces the screen tier.
confirm_case() {
  local shape="$2" screenfn="$3"
  local dir="$STUBROOT/confirm-$1"
  mkdir -p "$dir/bin" "$dir/home" "$dir/screens"
  local sock; sock="$(start_socket_stub "$dir/socket" "$OK_RESPONSES")"
  local nonce="deadbeef0000$1"
  printf '[CALL_ID: %s]\n%s' "$nonce" "$MULTILINE_MSG" > "$dir/payload.txt"
  chmod 600 "$dir/payload.txt"
  "$screenfn" > "$dir/screens/1.txt"; echo 1 > "$dir/screens/count"; echo 0 > "$dir/screens/cursor"
  if [[ "$shape" != "notarget" ]]; then
    local enc; enc=$(printf '%s' "$CALLEE_CWD" | sed 's|[^a-zA-Z0-9]|-|g')
    mkdir -p "$dir/home/.claude/projects/$enc"
    "$shape" "$nonce" > "$dir/home/.claude/projects/$enc/${CALLEE_SESSION}.jsonl"
  fi
  cp "$STUBROOT/paste_multiline/bin/cmux" "$dir/bin/cmux"
  local -a target=(--cwd "$CALLEE_CWD" --session "$CALLEE_SESSION")
  [[ "$shape" == "notarget" ]] && target=()
  CONFIRM_OUT="$(STUB_CALLLOG="$dir/calls.log" STUB_SCREENS="$dir/screens" \
    STUB_SURF="$SURF_UUID" STUB_WS="$WS_UUID" \
    CMUX_SOCKET_PATH="$sock" HOME="$dir/home" \
    HOTLINE_PASTE_CONFIRM_TRIES=3 HOTLINE_PASTE_CONFIRM_SLEEP=0.05 \
    PATH="$dir/bin:$PATH" bash "$PASTE_SCRIPT" \
    --surface "$SURF_UUID" --payload-file "$dir/payload.txt" --call-id "$nonce" \
    ${target[@]+"${target[@]}"} 2>&1)"
}

confirm_case 1 transcript_user_turn screen_scrolled
[[ "$CONFIRM_OUT" == *'"confirmed":"transcript"'* ]] \
  && pass "a user turn carrying the nonce confirms delivery from the transcript" \
  || fail "a user turn carrying the nonce confirms delivery from the transcript" "out: $CONFIRM_OUT"

# THE ONE THAT MATTERS: a busy REPL queues the paste and writes NO user turn at
# all, only a queued_command attachment. A verifier counting user turns reads
# this landed payload as lost and re-sends it.
confirm_case 2 transcript_queued screen_placeholder
[[ "$CONFIRM_OUT" == *'"confirmed":"transcript"'* ]] \
  && pass "a queued_command attachment confirms delivery (no user turn is written)" \
  || fail "a queued_command attachment confirms delivery (no user turn is written)" "out: $CONFIRM_OUT"

# SECONDARY TIER: the screen, for a callee whose transcript we cannot read.
confirm_case 3 notarget screen_pasted_placeholder
[[ "$CONFIRM_OUT" == *'"confirmed":"screen"'* ]] \
  && pass "a collapsed [Pasted text placeholder confirms delivery on screen" \
  || fail "a collapsed [Pasted text placeholder confirms delivery on screen" "out: $CONFIRM_OUT"

confirm_case 4 notarget screen_queued
[[ "$CONFIRM_OUT" == *'"confirmed":"screen"'* ]] \
  && pass "'Press up to edit queued messages' counts as landed" \
  || fail "'Press up to edit queued messages' counts as landed" "out: $CONFIRM_OUT"

# A scrolled viewport is NOT a failed send: cmux has no primitive to snap a
# terminal back to its live tail, so absence of the nonce proves nothing, and
# re-sending on it is a documented double-submit.
confirm_case 5 notarget screen_scrolled
[[ "$CONFIRM_OUT" == *'"confirmed":"screen"'* ]] \
  && pass "a scrolled viewport counts as landed, not as a lost paste" \
  || fail "a scrolled viewport counts as landed, not as a lost paste" "out: $CONFIRM_OUT"

# Nothing anywhere: report it rather than assuming ok:true meant delivery.
confirm_case 6 notarget screen_idle_empty
[[ "$CONFIRM_OUT" == *'"delivered":false'* && "$CONFIRM_OUT" == *"never appeared"* ]] \
  && pass "an unconfirmable paste is reported as undelivered, not as success" \
  || fail "an unconfirmable paste is reported as undelivered, not as success" "out: $CONFIRM_OUT"

echo ""
echo "  -- an unconfirmed paste falls back and leaves no corpse --"

CASE_RESPONSES="$OK_RESPONSES" run_case lost_paste screen_idle_empty -- --prompt "$MULTILINE_MSG"
CASE_RESPONSES=""
[[ "$OUT" == *'"fallback"'* && "$OUT" == *"never appeared"* ]] \
  && pass "a paste nobody can confirm returns the fresh-surface fallback" \
  || fail "a paste nobody can confirm returns the fresh-surface fallback" "out: $OUT"
[[ -n "$CASE_CALL_DIR" && -d "$CASE_CALL_DIR" ]] \
  && fail "the unconfirmed call dir is removed" "still present: $CASE_CALL_DIR" \
  || pass "the unconfirmed call dir is removed"

# ok:false from the socket: fall back, and do not pretend the screen said anything.
CASE_RESPONSES="$REJECT_RESPONSES" run_case rejected_paste screen_idle_empty -- --prompt "$MULTILINE_MSG"
CASE_RESPONSES=""
[[ "$OUT" == *'"fallback"'* && "$OUT" == *"terminal.paste"* ]] \
  && pass "a rejected terminal.paste returns the fallback and names the failure" \
  || fail "a rejected terminal.paste returns the fallback and names the failure" "out: $OUT"

# Unresolvable surface: fall back BEFORE any socket traffic.
CASE_ORPHAN_TREE=1 run_case orphan_tree screen_idle_empty -- --prompt "$MULTILINE_MSG"
CASE_ORPHAN_TREE=""
[[ "$OUT" == *'"fallback"'* && "$OUT" == *"not in the cmux tree"* ]] \
  && pass "a surface missing from the tree returns the fallback" \
  || fail "a surface missing from the tree returns the fallback" "out: $OUT"
[[ "$(request_count)" -eq 0 ]] \
  && pass "…and nothing is pasted anywhere" \
  || fail "…and nothing is pasted anywhere" "$(requests)"

CASE_NO_TREE=1 run_case no_tree screen_idle_empty -- --prompt "$MULTILINE_MSG"
CASE_NO_TREE=""
[[ "$OUT" == *'"fallback"'* && "$OUT" == *"cmux tree"* && "$(request_count)" -eq 0 ]] \
  && pass "an unreadable tree returns the fallback with nothing sent" \
  || fail "an unreadable tree returns the fallback with nothing sent" "out: $OUT"

# --- Surface gone → fallback, and nothing sent anywhere. --------------------
CASEDIR="$STUBROOT/gone"; mkdir -p "$CASEDIR/bin"
CALLLOG="$CASEDIR/calls.log"; : > "$CALLLOG"
REQLOG="$STUBROOT/poison-socket/requests.log"
echo "$(wc -l < "$REQLOG" | tr -d ' ')" > "$CASEDIR/reqbase"
cat > "$CASEDIR/bin/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CALLLOG"; printf '\n' >> "$STUB_CALLLOG"
case "$1" in
  read-screen) echo "Error: surface not found" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$CASEDIR/bin/cmux"
OUT="$(STUB_CALLLOG="$CALLLOG" CMUX_SOCKET_PATH="$POISON_SOCK" \
  PATH="$CASEDIR/bin:$PATH" bash "$SCRIPT_UNDER_TEST" \
  --surface "$SURF_UUID" --prompt "follow up" 2>&1)"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "a dead surface returns the fresh-surface fallback" \
  || fail "a dead surface returns the fresh-surface fallback" "out: $OUT"
[[ "$(request_count)" -eq 0 ]] \
  && pass "a dead surface receives nothing at all" \
  || fail "a dead surface receives nothing at all" "$(requests)"

echo ""
echo "  -- conditional input-box clear (06ws) --"

# --- Idle + empty box: no clear at all, message goes through. ---------------
CASE_RESPONSES="$OK_RESPONSES" run_case idle_empty screen_idle_empty screen_pasted_placeholder -- --prompt "follow up"
CASE_RESPONSES=""
[[ "$(clear_count)" -eq 0 ]] \
  && pass "idle REPL with an empty box gets NO Ctrl-C" \
  || fail "idle REPL with an empty box gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "idle REPL with an empty box: emits call_dir" \
  || fail "idle REPL with an empty box: emits call_dir" "out: $OUT"

# --- Empty box on a never-used REPL: the placeholder is not parked text. ----
CASE_RESPONSES="$OK_RESPONSES" run_case placeholder screen_placeholder screen_pasted_placeholder -- --prompt "follow up"
CASE_RESPONSES=""
[[ "$(clear_count)" -eq 0 ]] \
  && pass "placeholder hint is not mistaken for parked text" \
  || fail "placeholder hint is not mistaken for parked text" "log:"$'\n'"$(log_view)"

# --- Busy + empty box: still no clear, and the message is still sent. -------
#     Text into a busy REPL is enqueued and delivered; the destructive thing is
#     the interrupt, so it is the interrupt we withhold.
CASE_RESPONSES="$OK_RESPONSES" run_case busy_empty screen_busy_empty screen_queued -- --prompt "follow up"
CASE_RESPONSES=""
[[ "$(clear_count)" -eq 0 ]] \
  && pass "busy REPL with an empty box gets NO Ctrl-C" \
  || fail "busy REPL with an empty box gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "busy REPL with an empty box: message still sent, emits call_dir" \
  || fail "busy REPL with an empty box: message still sent, emits call_dir" "out: $OUT"

# --- Idle + parked text: clear, confirm it took, then paste. ----------------
CASE_RESPONSES="$OK_RESPONSES" run_case parked_clears \
  screen_idle_parked screen_idle_parked screen_idle_empty screen_pasted_placeholder -- --prompt "follow up"
CASE_RESPONSES=""
[[ "$(clear_count)" -ge 1 ]] \
  && pass "idle REPL with parked text IS cleared" \
  || fail "idle REPL with parked text IS cleared" "log:"$'\n'"$(log_view)"
[[ "$(clear_index)" -ge 0 && "$(request_count)" -eq 1 ]] \
  && pass "the clear precedes the paste" \
  || fail "the clear precedes the paste" "clear=$(clear_index) requests=$(request_count)"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "cleared box: emits call_dir" \
  || fail "cleared box: emits call_dir" "out: $OUT"

# --- Idle + parked text that will not clear: fall back, send nothing. -------
run_case parked_sticks screen_idle_parked screen_idle_parked screen_idle_parked -- --prompt "follow up"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "a box that will not clear returns the fresh-surface fallback" \
  || fail "a box that will not clear returns the fresh-surface fallback" "out: $OUT"
[[ "$(request_count)" -eq 0 ]] \
  && pass "a box that will not clear never receives the message" \
  || fail "a box that will not clear never receives the message" "$(requests)"

# --- Busy + parked text: no clear, nothing sent, fall back. -----------------
run_case busy_parked screen_busy_parked screen_busy_parked -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "busy REPL with parked text gets NO Ctrl-C" \
  || fail "busy REPL with parked text gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"fallback"'* && "$(request_count)" -eq 0 ]] \
  && pass "busy REPL with parked text falls back and receives nothing" \
  || fail "busy REPL with parked text falls back and receives nothing" "out: $OUT"

# --- Parked text on a REPL with no spinner but a changing screen. -----------
run_case parked_moving screen_parked_moving_a screen_parked_moving_b -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 && "$OUT" == *'"fallback"'* ]] \
  && pass "a changing screen counts as busy: no Ctrl-C, no paste, fallback" \
  || fail "a changing screen counts as busy: no Ctrl-C, no paste, fallback" "out: $OUT"

# --- Interrupted REPL: send nothing, fall back (06ws acceptance criteria). --
run_case interrupted screen_interrupted -- --prompt "follow up"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "an interrupted REPL returns the fresh-surface fallback, not exit 0 success" \
  || fail "an interrupted REPL returns the fresh-surface fallback, not exit 0 success" "out: $OUT"
[[ "$(clear_count)" -eq 0 && "$(request_count)" -eq 0 ]] \
  && pass "an interrupted REPL gets neither a Ctrl-C nor a paste" \
  || fail "an interrupted REPL gets neither a Ctrl-C nor a paste" "log:"$'\n'"$(log_view)"

echo ""
echo "  -- legacy cached handles --"

# Caches written by older plugin versions hold a positional surface:N ref. Reuse
# still accepts them (closing never will), so the tree lookup has to resolve a
# ref to the UUID pair terminal.paste needs.
CASE_RESPONSES="$OK_RESPONSES" CASE_SURFACE="surface:1" \
  run_case positional_ref screen_idle_empty screen_pasted_placeholder -- --prompt "follow up"
CASE_RESPONSES=""; CASE_SURFACE=""
[[ "$(request_field surface_id)" == "$SURF_UUID" && "$(request_field workspace_id)" == "$WS_UUID" ]] \
  && pass "a legacy surface:N handle resolves to the UUID pair the paste needs" \
  || fail "a legacy surface:N handle resolves to the UUID pair the paste needs" \
          "surf=$(request_field surface_id) ws=$(request_field workspace_id)"

# The whole point of the poison stubs: a leak is a test failure, not a stray pane
# or a paste into the developer's own REPL.
if [[ -s "$POISON_LOG" ]]; then
  fail "no test reaches the real cmux, claude, or control socket" "$(cat "$POISON_LOG")"
else
  pass "no test reaches the real cmux, claude, or control socket"
fi

echo ""
echo "cmux-reuse-surface: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
