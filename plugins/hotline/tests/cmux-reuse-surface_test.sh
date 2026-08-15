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
#      failing that, on screen, and a screen marker only counts if it was not
#      already there before the paste.
#
#      THE TWO FAILURE OUTCOMES ARE NOT INTERCHANGEABLE, and that is the point:
#        refused BEFORE anything was sent → fallback:fresh, call dir removed. The
#          callee received nothing, so delivering elsewhere is safe.
#        sent but UNCONFIRMED → undelivered:true, call dir and prompt KEPT. The
#          payload may already be in the callee's queue, and the fresh path would
#          re-deliver the same prompt into a --resume of the same session — running
#          the work order twice. Reported as a hard stop instead.
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
# Shared with dial_wrapper_test.sh via tests/lib/socket-stub-harness.sh: the stub
# server and the python3 argv shim were duplicated here before, which is how one
# copy learns about a new option and the other keeps passing without it.
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
trap 'socket_stub_cleanup; rm -rf "$STUBROOT" "$POISON_BIN"' EXIT

start_socket_stub() { socket_stub_start "$@"; }

# The default socket every case inherits is the poisoned one.
POISON_SOCK="$(start_socket_stub "$STUBROOT/poison-socket")"
: > "$STUBROOT/poison-socket/requests.log"

# Canned responses come from the shared harness (one definition of what a working
# cmux answers, so a suite cannot drift into testing against a fictional one).
socket_stub_write_responses "$STUBROOT/responses"
OK_RESPONSES="$STUBROOT/responses/ok.json"
REJECT_RESPONSES="$STUBROOT/responses/reject.json"
# terminal.replay render grids: what the box's text looks like in ATTRIBUTES, which is
# the only place placeholder and unsent input differ (claude-plugins-ff6g).
GHOST_RESPONSES="$STUBROOT/responses/replay-ghost.json"
GHOST_FOCUSED_RESPONSES="$STUBROOT/responses/replay-ghost-focused.json"
REAL_INPUT_RESPONSES="$STUBROOT/responses/replay-real.json"
REAL_THEN_GHOST_RESPONSES="$STUBROOT/responses/replay-real-then-ghost.json"
REPLAY_ERROR_RESPONSES="$STUBROOT/responses/replay-error.json"

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
# NO claude REPL AT ALL — the callee ran /exit, or claude crashed, and the surface
# is now showing a shell prompt. `❯` is the default prompt character of starship,
# pure and several oh-my-zsh themes, so the glyph alone proves nothing; what
# distinguishes the real box is the NO-BREAK SPACE padding, which a shell pads with
# an ordinary space instead. Pasting a work order here with submit_key:"return"
# would make the SHELL RUN IT, line by line.
screen_shell_prompt() {
  printf '~/Code/target on  main\n%s%s\n' "$GLYPH" " "
}
# A shell prompt with no path segment above it — the barest possible version.
screen_shell_prompt_bare() {
  printf '%s%s\n' "$GLYPH" " "
}
# A never-used REPL shows a greyed placeholder hint inside an EMPTY box.
screen_placeholder() {
  printf '%s\n%s%sTry "how does <filepath> work?"\n%s\n' \
    "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# A large paste that SUBMITTED. CC collapsed it to a placeholder, so the nonce is
# genuinely not on screen; what proves it landed is the placeholder echoed as a turn
# ABOVE the box (plain space after the glyph, like every transcript echo) while the
# live box (glyph + U+00A0) is empty again.
#
# The echo is the load-bearing part. A placeholder sitting IN the live box is the
# opposite outcome — arrived, never submitted — and confirming on it is the y4rl
# false positive (see screen_pasted_parked below).
screen_pasted_placeholder() {
  printf '%s%s [Pasted text +75 lines]\n%s\n%s%s\n%s\n' \
    "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# The same paste PARKED: the placeholder is in the live input box and nowhere else.
screen_pasted_parked() {
  printf '%s\n%s%s[Pasted text +75 lines]\n%s\n' \
    "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# Queued against a busy REPL. The hint is drawn INSIDE the box, as a placeholder —
# so screen confirmation cannot find it by looking outside the box, and the box-line
# exemption in cmux-paste.sh is what makes a queued delivery provable at all. It is
# also the only screen-side proof of this landing shape: no user turn is written.
screen_queued() {
  printf '%s%s Run the earlier thing\n\n%s Working… (5s · ↓ 12 tokens)\n%s\n%s%sPress up to edit queued messages\n%s\n' \
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
#   CASE_RENDER_GRID non-empty → `cmux capabilities` advertises
#                    terminal.render_grid.v1, so the placeholder judgement may run
CASEDIR=""
OUT=""
CALLLOG=""
REQLOG=""
PYLOG=""
CASE_CALL_DIR=""
CASE_HAD_PAYLOAD_FILE=false
CASE_PAYLOAD_MODE=""
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
  capabilities)
    # Absent by default: a cmux that cannot render a styled grid must leave the
    # placeholder judgement unable to answer, which is the fail-closed direction.
    [[ -n "${STUB_RENDER_GRID:-}" ]] \
      && printf '{"capabilities": ["terminal.bytes.v1", "terminal.render_grid.v1"]}\n'
    exit 0 ;;
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

  write_python3_shim "$CASEDIR/bin" "$PYLOG"

  local -a target=()
  if [[ "${CASE_TARGET-unset}" == "unset" ]]; then
    target=(--cwd "$CALLEE_CWD" --session "$CALLEE_SESSION")
  fi

  OUT="$(STUB_CALLLOG="$CALLLOG" STUB_SCREENS="$CASEDIR/screens" \
    STUB_SURF="$SURF_UUID" STUB_WS="$WS_UUID" \
    STUB_NO_TREE="${CASE_NO_TREE:-}" STUB_ORPHAN_TREE="${CASE_ORPHAN_TREE:-}" \
    STUB_RENDER_GRID="${CASE_RENDER_GRID:-}" \
    CMUX_SOCKET_PATH="$sock" HOME="$CASEDIR/home" \
    HOTLINE_PASTE_CONFIRM_TRIES=3 HOTLINE_PASTE_CONFIRM_SLEEP=0.05 \
    PATH="$CASEDIR/bin:$PATH" bash "$SCRIPT_UNDER_TEST" \
    --surface "${CASE_SURFACE:-$SURF_UUID}" \
    ${target[@]+"${target[@]}"} "${extra[@]}" 2>&1)"

  # Any call_dir the script created is a temp dir. Snapshot what the assertions
  # need out of it BEFORE removing it, so no case has to leave one behind.
  CASE_CALL_DIR=""
  CASE_HAD_PAYLOAD_FILE=false
  CASE_PAYLOAD_MODE=""
  CASE_HAS_MESSAGE=false
  local cd_path
  cd_path="$(printf '%s' "$OUT" | sed -n 's/.*"call_dir": *"\([^"]*\)".*/\1/p')"
  if [[ -n "$cd_path" ]]; then
    CASE_CALL_DIR="$cd_path"
    if [[ -f "$cd_path/pending_paste.md" ]]; then
      CASE_HAD_PAYLOAD_FILE=true
      CASE_PAYLOAD_MODE=$(stat -c '%a' "$cd_path/pending_paste.md" 2>/dev/null \
        || stat -f '%Lp' "$cd_path/pending_paste.md" 2>/dev/null)
    fi
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
# Requests for ONE method. A case that consults terminal.replay makes more than one
# request, so "did the paste go out" and "was the grid read" need separate counts.
method_count() { requests | grep -cF "\"method\":\"$1\"" || true; }
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
# confirm_case <n> <shape-fn|notarget> <post-paste-screen-fn> [baseline-screen-fn]
#
# Exercises the confirmation tiers directly against cmux-paste.sh rather than
# through the reuse script, because that is the only place the nonce is an INPUT:
# reuse mints its own, so no fixture written beforehand could contain it.
# "notarget" withholds --cwd/--session, which is what forces the screen tier.
#
# TWO screens, in order: what the surface showed BEFORE the paste, then what it
# shows after. That ordering is the whole point of the recency baseline — a screen
# marker only counts as evidence if it was not already there. The default baseline
# is an idle empty box, i.e. a surface with no landing markers on it yet.
confirm_case() {
  local shape="$2" screenfn="$3" basefn="${4:-screen_idle_empty}"
  local dir="$STUBROOT/confirm-$1"
  mkdir -p "$dir/bin" "$dir/home" "$dir/screens"
  local sock; sock="$(start_socket_stub "$dir/socket" "$OK_RESPONSES")"
  local nonce="deadbeef0000$1"
  printf '[CALL_ID: %s]\n%s' "$nonce" "$MULTILINE_MSG" > "$dir/payload.txt"
  chmod 600 "$dir/payload.txt"
  "$basefn"  > "$dir/screens/1.txt"
  "$screenfn" > "$dir/screens/2.txt"
  echo 2 > "$dir/screens/count"; echo 0 > "$dir/screens/cursor"
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

# …but only where it is an ECHO. The same placeholder sitting in the LIVE INPUT BOX
# is the opposite fact — the payload arrived and its submit was dropped — and the
# screen tier confirming on it is what suppressed the parked retry live
# (claude-plugins-y4rl). Nothing else on screen has changed, so the marker is fresh
# and the only thing withholding confirmation is where it is rendered.
confirm_case 3b notarget screen_pasted_parked
[[ "$CONFIRM_OUT" != *'"confirmed":"screen"'* ]] \
  && pass "the same placeholder in the LIVE box does NOT confirm on screen" \
  || fail "the same placeholder in the LIVE box does NOT confirm on screen" "out: $CONFIRM_OUT"

# The queued hint is the BOX's content, which is where claude actually draws it. It
# still confirms: a placeholder proves the input VALUE is empty, so our payload is not
# parked behind it, and the hint proves the queue is non-empty. This is the one marker
# the box exclusion exempts — without the exemption a queued delivery has no proof at
# all, because there is no user turn either.
confirm_case 4 notarget screen_queued
[[ "$CONFIRM_OUT" == *'"confirmed":"screen"'* ]] \
  && pass "'Press up to edit queued messages' AS the box content counts as landed" \
  || fail "'Press up to edit queued messages' AS the box content counts as landed" "out: $CONFIRM_OUT"

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
# sent:true is what tells the caller re-delivering is unsafe. Without it, an
# unconfirmed paste is indistinguishable from one the socket refused.
[[ "$CONFIRM_OUT" == *'"sent":true'* ]] \
  && pass "…and reports sent:true, so the caller knows it may already have landed" \
  || fail "…and reports sent:true, so the caller knows it may already have landed" "out: $CONFIRM_OUT"

# STALE MARKERS MUST NOT CONFIRM. `[Pasted text`, `Press up to edit queued` and
# `Jump to bottom` are generic chrome, and reuse is by definition a surface a
# PREVIOUS exchange has already been through — so each of them is very often
# sitting in the viewport before this paste is sent. Matched blind, they confirm a
# delivery that never happened, and the caller then blocks on wait-for-response
# until it times out. A marker only counts if it was absent from the pre-paste
# baseline.
for stale in screen_pasted_placeholder screen_queued screen_scrolled; do
  confirm_case "stale-${stale#screen_}" notarget "$stale" "$stale"
  [[ "$CONFIRM_OUT" == *'"delivered":false'* ]] \
    && pass "a $stale marker already on screen before the paste does NOT confirm it" \
    || fail "a $stale marker already on screen before the paste does NOT confirm it" "out: $CONFIRM_OUT"
done

# …and the nonce is exempt, because a fresh nonce cannot be stale. Baseline and
# post-paste screen are identical here, yet the nonce still confirms.
confirm_case nonce-exempt transcript_user_turn screen_idle_empty screen_idle_empty
[[ "$CONFIRM_OUT" == *'"confirmed":"transcript"'* ]] \
  && pass "the nonce confirms regardless of the baseline (it cannot be stale)" \
  || fail "the nonce confirms regardless of the baseline (it cannot be stale)" "out: $CONFIRM_OUT"

# A callee under a SYMLINKED cwd writes its transcript under the resolved path:
# a session in /tmp/x on macOS lands in ~/.claude/projects/-private-tmp-x, not
# -tmp-x. Deriving the project dir only from the path the caller passed made this
# tier miss every time for such a callee, and miss silently — the screen tier
# answered and a delivery that had landed perfectly reported confirmed:"screen".
# Caught live, not in a stub.
sym_dir="$STUBROOT/confirm-symlink"
mkdir -p "$sym_dir/bin" "$sym_dir/home" "$sym_dir/screens" "$sym_dir/real"
ln -s "$sym_dir/real" "$sym_dir/link"
sym_sock="$(start_socket_stub "$sym_dir/socket" "$OK_RESPONSES")"
sym_nonce="deadbeefsymlink1"
printf '[CALL_ID: %s]\nthe payload' "$sym_nonce" > "$sym_dir/payload.txt"
chmod 600 "$sym_dir/payload.txt"
# The screen offers NO landing signal, so only the transcript tier can confirm.
screen_idle_empty > "$sym_dir/screens/1.txt"
echo 1 > "$sym_dir/screens/count"; echo 0 > "$sym_dir/screens/cursor"
sym_enc=$(printf '%s' "$(cd "$sym_dir/real" && pwd -P)" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$sym_dir/home/.claude/projects/$sym_enc"
transcript_user_turn "$sym_nonce" > "$sym_dir/home/.claude/projects/$sym_enc/${CALLEE_SESSION}.jsonl"
cp "$STUBROOT/paste_multiline/bin/cmux" "$sym_dir/bin/cmux"
SYM_OUT="$(STUB_CALLLOG="$sym_dir/calls.log" STUB_SCREENS="$sym_dir/screens" \
  STUB_SURF="$SURF_UUID" STUB_WS="$WS_UUID" \
  CMUX_SOCKET_PATH="$sym_sock" HOME="$sym_dir/home" \
  HOTLINE_PASTE_CONFIRM_TRIES=3 HOTLINE_PASTE_CONFIRM_SLEEP=0.05 \
  PATH="$sym_dir/bin:$PATH" bash "$PASTE_SCRIPT" \
  --surface "$SURF_UUID" --payload-file "$sym_dir/payload.txt" --call-id "$sym_nonce" \
  --cwd "$sym_dir/link" --session "$CALLEE_SESSION" 2>&1)"
[[ "$SYM_OUT" == *'"confirmed":"transcript"'* ]] \
  && pass "a callee under a symlinked cwd is still confirmed from its transcript" \
  || fail "a callee under a symlinked cwd is still confirmed from its transcript" "out: $SYM_OUT"

echo ""
echo "  -- an unconfirmed paste falls back and leaves no corpse --"

# THE FALSE-NEGATIVE DIRECTION, which is the dangerous one. The socket ACCEPTED the
# paste and confirmation could not prove where it went. That must NOT become
# fallback:fresh: the caller answers a fresh fallback by opening a new surface and
# re-delivering the SAME prompt into a --resume of the SAME session, so a payload
# that actually landed gets executed TWICE. (The round-1 tests pinned only the
# false-positive direction — stale markers must not confirm — which is how this
# stayed open.)
CASE_RESPONSES="$OK_RESPONSES" run_case lost_paste screen_idle_empty -- --prompt "$MULTILINE_MSG"
CASE_RESPONSES=""
[[ "$OUT" == *'"undelivered": true'* || "$OUT" == *'"undelivered":true'* ]] \
  && pass "an accepted-but-unconfirmed paste reports undelivered, NOT a fresh fallback" \
  || fail "an accepted-but-unconfirmed paste reports undelivered, NOT a fresh fallback" "out: $OUT"
[[ "$OUT" != *'"fallback"'* ]] \
  && pass "…and never says fallback:fresh (which would re-deliver the same prompt)" \
  || fail "…and never says fallback:fresh (which would re-deliver the same prompt)" "out: $OUT"

# The prompt is the only copy left, so the payload survives in the call dir — the
# opposite of the pre-paste refusals, which delete it. (run_case snapshots the dir
# and then removes it, so these read the snapshot.)
[[ -n "$CASE_CALL_DIR" ]] \
  && pass "the call dir survives an unconfirmed paste (it holds the only copy)" \
  || fail "the call dir survives an unconfirmed paste (it holds the only copy)" "out: $OUT"
$CASE_HAD_PAYLOAD_FILE \
  && pass "…and pending_paste.md is still in it" \
  || fail "…and pending_paste.md is still in it" "call_dir=$CASE_CALL_DIR"
[[ "$CASE_PAYLOAD_MODE" == "600" ]] \
  && pass "…still owner-only" \
  || fail "…still owner-only" "mode=$CASE_PAYLOAD_MODE"
[[ "$OUT" == *"$CASE_CALL_DIR/pending_paste.md"* ]] \
  && pass "…and the outcome names it, so the caller can recover the prompt" \
  || fail "…and the outcome names it, so the caller can recover the prompt" "out: $OUT"

# A paste the SOCKET refused never reached the callee, so the fresh fallback is
# safe here — this is the line between the two outcomes.
CASE_RESPONSES="$REJECT_RESPONSES" run_case rejected_paste screen_idle_empty -- --prompt "$MULTILINE_MSG"
CASE_RESPONSES=""
[[ "$OUT" == *'"fallback"'* && "$OUT" == *"terminal.paste"* ]] \
  && pass "a rejected terminal.paste returns the fallback and names the failure" \
  || fail "a rejected terminal.paste returns the fallback and names the failure" "out: $OUT"
[[ "$OUT" != *'"undelivered"'* ]] \
  && pass "…and is NOT reported as undelivered (nothing left this machine)" \
  || fail "…and is NOT reported as undelivered (nothing left this machine)" "out: $OUT"

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
echo "  -- a ghost placeholder is an EMPTY box, not parked text (ff6g) --"

# The bug: `cmux read-screen` is plain text, so claude's ghost suggested prompt (and
# its queued-messages hint, and `Message @agent…`) is byte-identical to unsent typed
# input. The gate read every one of them as parked text, fired a real Ctrl-C at an
# idle callee, watched the placeholder survive it (there is nothing to clear — the
# input's VALUE is empty), and bounced to a fresh surface. Surfaces stacked, and two
# consecutive Ctrl-Cs exit a claude REPL outright.
#
# The discriminator is the attribute the text read discards: claude renders a
# placeholder DIM. `terminal.replay` carries it as faint:true per span.

# --- Ghost in the box: NO Ctrl-C, and the follow-up is delivered. ------------
CASE_RESPONSES="$GHOST_RESPONSES" CASE_RENDER_GRID=1 \
  run_case ghost_box screen_idle_parked screen_pasted_placeholder -- --prompt "follow up"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
# Both halves, because "no Ctrl-C" alone also describes a refusal that never got as
# far as clearing — the assertion has to say the surface was USED.
[[ "$(clear_count)" -eq 0 && "$OUT" != *'"fallback"'* ]] \
  && pass "a box whose text renders DIM gets NO Ctrl-C and no fresh-surface bounce" \
  || fail "a box whose text renders DIM gets NO Ctrl-C and no fresh-surface bounce" \
          "out: $OUT log:"$'\n'"$(log_view)"
[[ "$(method_count terminal.paste)" -eq 1 && "$OUT" == *'"call_dir"'* ]] \
  && pass "…and the follow-up is pasted into that surface instead of a fresh one" \
  || fail "…and the follow-up is pasted into that surface instead of a fresh one" "out: $OUT"
[[ "$(method_count terminal.replay)" -ge 1 ]] \
  && pass "…having asked terminal.replay, not guessed from the text" \
  || fail "…having asked terminal.replay, not guessed from the text" "$(requests)"

# --- The FOCUSED render of the same ghost. -----------------------------------
# A focused terminal draws the placeholder's first character as the block cursor:
# that one cell comes back inverse and NOT faint while the rest stays dim. Rejecting
# the whole row on it would make the fix work only on unfocused surfaces.
CASE_RESPONSES="$GHOST_FOCUSED_RESPONSES" CASE_RENDER_GRID=1 \
  run_case ghost_focused screen_idle_parked screen_pasted_placeholder -- --prompt "follow up"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
[[ "$(clear_count)" -eq 0 && "$OUT" == *'"call_dir"'* ]] \
  && pass "one inverse cursor cell over a dim placeholder is still a placeholder" \
  || fail "one inverse cursor cell over a dim placeholder is still a placeholder" "out: $OUT log:"$'\n'"$(log_view)"

# --- REAL unsent text: today's clear-then-verify path, unchanged. ------------
# The direction that must not regress. A false positive here pastes a work order on
# top of a human's half-typed words, which is why the predicate fails closed.
CASE_RESPONSES="$REAL_INPUT_RESPONSES" CASE_RENDER_GRID=1 \
  run_case real_input screen_idle_parked screen_idle_parked screen_idle_empty screen_pasted_placeholder \
  -- --prompt "follow up"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
[[ "$(clear_count)" -ge 1 && "$(clear_index)" -ge 0 ]] \
  && pass "a box whose text renders at NORMAL intensity is still cleared first" \
  || fail "a box whose text renders at NORMAL intensity is still cleared first" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "…and then delivered, exactly as before" \
  || fail "…and then delivered, exactly as before" "out: $OUT"

# --- The post-clear re-read gets the same question. --------------------------
# The Ctrl-C empties the box and claude immediately draws a placeholder into it.
# Reading that as "still dirty" refuses a clear that demonstrably worked — the same
# bug one step later. (The grid answers real-input first, placeholder second.)
CASE_RESPONSES="$REAL_THEN_GHOST_RESPONSES" CASE_RENDER_GRID=1 \
  run_case cleared_into_ghost screen_idle_parked screen_idle_parked screen_idle_parked screen_pasted_placeholder \
  -- --prompt "follow up"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
[[ "$(clear_count)" -ge 1 ]] \
  && pass "real text is cleared, as before" \
  || fail "real text is cleared, as before" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"call_dir"'* && "$OUT" != *'"fallback"'* ]] \
  && pass "…and a placeholder drawn into the emptied box does NOT read as a failed clear" \
  || fail "…and a placeholder drawn into the emptied box does NOT read as a failed clear" "out: $OUT"

# --- FAIL CLOSED, both ways. -------------------------------------------------
# An RPC the socket refuses proves nothing, so the box stays "real text" and the
# clear/verify path runs untouched.
CASE_RESPONSES="$REPLAY_ERROR_RESPONSES" CASE_RENDER_GRID=1 \
  run_case replay_refused screen_idle_parked screen_idle_parked screen_idle_empty screen_pasted_placeholder \
  -- --prompt "follow up"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
[[ "$(clear_count)" -ge 1 && "$OUT" == *'"call_dir"'* ]] \
  && pass "a refused terminal.replay falls back to today's clear-then-verify" \
  || fail "a refused terminal.replay falls back to today's clear-then-verify" "out: $OUT log:"$'\n'"$(log_view)"

# A cmux without terminal.render_grid.v1 must not even ASK — the grid staged here
# says "ghost", and the capability gate is the only thing keeping it unread.
CASE_RESPONSES="$GHOST_RESPONSES" \
  run_case no_render_grid screen_idle_parked screen_idle_parked screen_idle_empty screen_pasted_placeholder \
  -- --prompt "follow up"
CASE_RESPONSES=""
[[ "$(method_count terminal.replay)" -eq 0 ]] \
  && pass "a cmux without terminal.render_grid.v1 is never asked for a grid" \
  || fail "a cmux without terminal.render_grid.v1 is never asked for a grid" "$(requests)"
[[ "$(clear_count)" -ge 1 && "$OUT" == *'"call_dir"'* ]] \
  && pass "…and the box is treated as real text (today's behavior)" \
  || fail "…and the box is treated as real text (today's behavior)" "out: $OUT log:"$'\n'"$(log_view)"

# An unresolvable surface cannot be addressed for the RPC either. It falls back for
# its own reason before any of this matters, and asks for no grid on the way out.
CASE_ORPHAN_TREE=1 CASE_RENDER_GRID=1 \
  run_case ghost_orphan screen_idle_parked screen_idle_parked screen_idle_parked -- --prompt "follow up"
CASE_ORPHAN_TREE=""; CASE_RENDER_GRID=""
[[ "$OUT" == *'"fallback"'* && "$(method_count terminal.replay)" -eq 0 ]] \
  && pass "a surface absent from the tree yields no grid lookup and still falls back" \
  || fail "a surface absent from the tree yields no grid lookup and still falls back" "out: $OUT"

echo ""
echo "  -- a surface with no REPL left in it is refused, not pasted into --"

# The severe one. A surface whose claude has exited is still readable, and its
# cached handle still resolves — but what is drawn is a SHELL PROMPT. None of the
# other gates notice: repl_is_interrupted looks for interrupt wording,
# repl_looks_busy for a spinner, and input_box_content would at most report the
# prompt line as parked text. Delivering here does not lose the payload; it hands
# the whole work order to a shell and presses Return.
for shellfix in screen_shell_prompt screen_shell_prompt_bare; do
  CASE_RESPONSES="$OK_RESPONSES" run_case "$shellfix" "$shellfix" -- --prompt "$MULTILINE_MSG"
  CASE_RESPONSES=""
  [[ "$OUT" == *'"fallback"'* && "$OUT" == *"no claude input box"* ]] \
    && pass "$shellfix: a shell prompt is refused with the fresh-surface fallback" \
    || fail "$shellfix: a shell prompt is refused with the fresh-surface fallback" "out: $OUT"
  [[ "$(request_count)" -eq 0 ]] \
    && pass "$shellfix: nothing is pasted at the shell" \
    || fail "$shellfix: nothing is pasted at the shell" "$(requests)"
  [[ "$(clear_count)" -eq 0 ]] \
    && pass "$shellfix: no Ctrl-C is sent to it either" \
    || fail "$shellfix: no Ctrl-C is sent to it either" "$(log_view)"
done

# The same discriminator guards the first-contact wait: --wait-box must not accept
# a shell prompt as "the REPL is up".
box_dir="$STUBROOT/waitbox-shell"
mkdir -p "$box_dir/bin" "$box_dir/screens"
box_sock="$(start_socket_stub "$box_dir/socket" "$OK_RESPONSES")"
printf '[CALL_ID: waitboxnonce1]\n%s' "$MULTILINE_MSG" > "$box_dir/payload.txt"
screen_shell_prompt > "$box_dir/screens/1.txt"
echo 1 > "$box_dir/screens/count"; echo 0 > "$box_dir/screens/cursor"
cp "$STUBROOT/paste_multiline/bin/cmux" "$box_dir/bin/cmux"
BOX_OUT="$(STUB_CALLLOG="$box_dir/calls.log" STUB_SCREENS="$box_dir/screens" \
  STUB_SURF="$SURF_UUID" STUB_WS="$WS_UUID" \
  CMUX_SOCKET_PATH="$box_sock" HOME="$box_dir" \
  PATH="$box_dir/bin:$PATH" bash "$PASTE_SCRIPT" \
  --surface "$SURF_UUID" --payload-file "$box_dir/payload.txt" \
  --call-id waitboxnonce1 --wait-box 1 2>&1)"
[[ "$BOX_OUT" == *'"delivered":false'* && "$BOX_OUT" == *"never drew a claude input box"* ]] \
  && pass "--wait-box refuses a shell prompt rather than pasting into it" \
  || fail "--wait-box refuses a shell prompt rather than pasting into it" "out: $BOX_OUT"
[[ ! -s "$box_dir/socket/requests.log" ]] \
  && pass "…and no paste request is made at all" \
  || fail "…and no paste request is made at all" "$(cat "$box_dir/socket/requests.log")"

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
