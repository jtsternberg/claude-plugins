#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-paste.sh's TWO-PASTE first-contact delivery
# (claude-plugins-pmgb).
#
# THE BUG. CC's TUI collapses any single paste over ~800 chars or 3 lines into a
# `[Pasted text +N lines]` placeholder. First contact delivers a
# `/hotline:…-ringing <work order>` payload; when the work order is that large the
# whole paste collapses, the buffer no longer starts with `/`, the slash command
# never parses, and the callee gets the work order as PLAIN TEXT with no ringing
# protocol — no STATUS, no call_id. The caller's wait-for-response then misreads
# the silence as a reassigned callee. The old one-paste path had this bug; the
# argv launch it replaced did not, because claude parsed the command at startup
# regardless of size.
#
# THE FIX. A slash-command payload WITH a body is delivered as two pastes: the
# invocation line alone (small, single line, renders verbatim so the command
# parses), then the body (its placeholder expands back inside the command args on
# submit — probe-verified live on CC 2.1.226), then a real Enter key event to
# submit. A payload that is NOT a slash command, or a slash command with no body,
# takes the one-paste path unchanged.
#
# WHAT A STUB CAN AND CANNOT SEE. No claude runs here, so "the ringing skill
# loaded" is asserted by its mechanical precondition: the invocation rode its own
# paste, that paste is a single line starting with `/hotline:…-ringing`, and it is
# under CC's collapse threshold — so CC cannot collapse it and will parse it. The
# end-to-end "skill actually loaded" is the job of the live smoke in the pmgb work
# order, not of this suite.
#
# Two stub layers, same as cmux-reuse-surface_test.sh: `cmux` is a PATH stub
# (read-screen serves a box-drawn screen plus whatever the socket echoed, so
# confirmation finds the nonce; send-key is logged), and $CMUX_SOCKET_PATH points
# at the shared python socket stub that logs every request line.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$HOTLINE_DIR/skills/dial/scripts/cmux-paste.sh"
REAL_PYTHON3="$(command -v python3)"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

if [[ -z "$REAL_PYTHON3" ]]; then
  echo "cmux-paste-slash-split: SKIP — python3 not available (the control-socket helper needs it)"
  exit 0
fi

GLYPH=$'\xe2\x9d\xaf'          # ❯
NBSP=$'\xc2\xa0'              # the box's NO-BREAK SPACE padding
RULE="$(printf '─%.0s' {1..40})"

# Stable handles. Passing --workspace with a UUID surface lets cmux-paste.sh skip
# the tree walk, so no `cmux tree` stub is needed.
SURF_UUID="aaaa0000-1111-4111-8111-111111111111"
WS_UUID="bbbb0000-2222-4222-8222-222222222222"

STUBROOT="$(mktemp -d)"
POISON_LOG="$STUBROOT/violations"
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
trap 'socket_stub_cleanup; rm -rf "$STUBROOT"' EXIT

socket_stub_write_responses "$STUBROOT/responses"
OK_RESPONSES="$STUBROOT/responses/ok.json"

# Confirmation budget: the screen tier answers immediately here, and no callee
# writes a transcript, so keep the polls short.
export HOTLINE_PASTE_CONFIRM_TRIES=3
export HOTLINE_PASTE_CONFIRM_SLEEP=0.05

# A cmux PATH stub. read-screen serves the submitted payload as a REPL renders it
# in its TRANSCRIPT, and THEN a box-drawn screen, so --wait-box passes and
# repl_box_present fires on the NBSP-padded ❯. send-key is logged so the submit
# keystroke can be asserted.
#
# TWO THINGS ARE MODELLED HERE, and both are load-bearing for the readers:
#
#   ORDER — a terminal draws the input box at the BOTTOM, under the transcript.
#   Emitting the box first makes the fixture indistinguishable from a screen whose
#   box has scrolled away, and it breaks the readers outright: they take the
#   live-screen TAIL of a scroll-immune read (repl-state.sh), so the box has to be
#   in the last rows. Do not flip it.
#
#   COLLAPSE — Claude Code renders a submitted paste over ~800 chars or 3 lines as
#   a one-line `[Pasted text +N lines]` echo, not as N literal lines. That is the
#   whole reason this suite exists, and a stub that echoes the raw lines instead
#   overstates how much of the payload is on screen: it puts the nonce back in the
#   transcript, where a real large paste never leaves it, and pushes the box tens
#   of rows down. Small payloads echo verbatim, which is why the control case can
#   still find its nonce (claude-plugins-r465.5/.8, -pmgb). This stub is the only
#   one that models the collapse — dial_wrapper_test.sh's and cmux-call_test.sh's
#   still echo the raw lines, and claude-plugins-7u9g is what closing that costs.
#
# The transcript echo uses a PLAIN space after the glyph — the live box is the one
# padded with U+00A0, and confirmation depends on telling them apart.
make_cmux() {  # make_cmux <bindir> <echo-file> <sendkey-log>
  local bindir="$1" echo_file="$2" sendkey_log="$3"
  mkdir -p "$bindir"
  cat > "$bindir/cmux" <<EOF
#!/usr/bin/env bash
render_transcript() {
  [[ -f "$echo_file" ]] || return 0
  local lines bytes
  lines=\$(wc -l < "$echo_file" | tr -d ' ')
  bytes=\$(wc -c < "$echo_file" | tr -d ' ')
  if (( lines > 3 || bytes > 800 )); then
    printf '%s%s [Pasted text +%s lines]\n' "$GLYPH" " " "\$lines"
  else
    cat "$echo_file"
  fi
}
case "\$1" in
  read-screen)
    render_transcript
    printf '%s\n%s%s\n%s\n' "$RULE" "$GLYPH" "$NBSP" "$RULE"
    exit 0 ;;
  send-key)
    echo "\$*" >> "$sendkey_log"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bindir/cmux"
}

# Decode the params of the Nth terminal.paste request (1-based).
nth_paste() {  # nth_paste <requests.log> <n> [field]
  local log="$1" n="$2" field="${3:-text}"
  grep -F '"terminal.paste"' "$log" 2>/dev/null | sed -n "${n}p" \
    | "$REAL_PYTHON3" -c '
import json,sys
line = sys.stdin.read().strip()
if not line: sys.exit(0)
# cmux-rpc.py may prefix the request with the capability envelope on the same line.
if line.startswith("_cmux_capability_v1 "):
    line = line.split(" ", 2)[2]
print(json.loads(line)["params"].get(sys.argv[1], ""), end="")
' "$field" 2>/dev/null
}
paste_count() { grep -cF '"terminal.paste"' "$1" 2>/dev/null || echo 0; }

# run_paste <case-dir> <payload-file> <call-id>  → the JSON cmux-paste.sh emits
run_paste() {
  local dir="$1" payload="$2" call_id="$3"
  local bin="$dir/bin" sock echo_file="$dir/echo" sendkey="$dir/sendkey" argvlog="$dir/py-argv"
  : > "$echo_file"; : > "$sendkey"; : > "$argvlog"
  make_cmux "$bin" "$echo_file" "$sendkey"
  write_python3_shim "$bin" "$argvlog"
  sock="$(socket_stub_start "$dir/sock" "$OK_RESPONSES" "$echo_file")"
  PATH="$bin:$PATH" CMUX_SOCKET_PATH="$sock" \
    bash "$SCRIPT_UNDER_TEST" --surface "$SURF_UUID" --workspace "$WS_UUID" \
      --payload-file "$payload" --call-id "$call_id" --wait-box 3 2>/dev/null
}

echo "cmux-paste.sh two-paste first-contact split:"

# ---------------------------------------------------------------------------
# 1. LARGE first contact — a work order well over 800 chars AND 3 lines.
#    This is the exact shape the regression dropped. The invocation must ride its
#    own small paste; the body must ride a second paste; neither may submit; an
#    Enter keystroke submits.
# ---------------------------------------------------------------------------
c1="$STUBROOT/large"; mkdir -p "$c1"
NONCE1="abc123def4560001"
INVITE1="/hotline:hotline-ringing [CALL_ID: $NONCE1] [MODE: work_order] [CALLER: /Users/x/proj] [SESSION: sess-1]"
{
  printf '%s\n' "$INVITE1"
  for i in $(seq -w 1 40); do
    printf 'BODYMARK line %s — %s\n' "$i" "$(printf 'q%.0s' {1..60})"
  done
} > "$c1/payload.md"
[[ "$(wc -c < "$c1/payload.md")" -gt 800 && "$(wc -l < "$c1/payload.md")" -gt 3 ]]
check "fixture crosses the collapse threshold (>800 chars AND >3 lines)" $? \
  "bytes=$(wc -c < "$c1/payload.md") lines=$(wc -l < "$c1/payload.md")"

OUT1="$(run_paste "$c1" "$c1/payload.md" "$NONCE1")"
LOG1="$c1/sock/requests.log"

[[ "$(jq -r '.delivered' <<<"$OUT1" 2>/dev/null)" == "true" ]]
check "large first contact is delivered and confirmed" $? "out=$OUT1"

[[ "$(paste_count "$LOG1")" -eq 2 ]]
check "large first contact is TWO pastes, not one" $? "count=$(paste_count "$LOG1")"

[[ "$(nth_paste "$LOG1" 1)" == "$INVITE1" ]]
check "paste 1 is the invocation line ALONE (starts with the slash command)" $? \
  "paste1=$(nth_paste "$LOG1" 1)"

# The mechanical precondition for the ringing skill loading: paste 1 cannot be
# collapsed by CC, because it is a single line under the ~800-char threshold.
inv1="$(nth_paste "$LOG1" 1)"
[[ "$inv1" == /hotline:*-ringing* && "$inv1" != *$'\n'* && "${#inv1}" -le 800 && "$inv1" != *BODYMARK* ]]
check "paste 1 is one line, under 800 chars, and carries no body — so CC parses it" $? \
  "len=${#inv1} paste1=$inv1"

body1="$(nth_paste "$LOG1" 2)"
grep -qF 'BODYMARK line 01' <<<"$body1" && grep -qF 'BODYMARK line 40' <<<"$body1"
check "paste 2 carries the full work-order body" $? "paste2len=${#body1}"

[[ "$(nth_paste "$LOG1" 1 submit_key)" == "none" \
   && "$(nth_paste "$LOG1" 2 submit_key)" == "none" ]]
check "neither paste submits (submit_key=none on both)" $? \
  "k1=$(nth_paste "$LOG1" 1 submit_key) k2=$(nth_paste "$LOG1" 2 submit_key)"

grep -qiE '(^| )(enter|return)( |$)' "$c1/sendkey" 2>/dev/null
check "a separate Enter keystroke submits the two-paste sequence" $? \
  "sendkey=$(cat "$c1/sendkey" 2>/dev/null)"

# The whole reason terminal.paste exists: the payload rides a file path, never an
# argv where `ps` would publish the work order (claude-plugins-86ka).
if grep -qF 'BODYMARK' "$c1/py-argv" 2>/dev/null; then
  fail "the work order never reaches python3's argv" "argv=$(cat "$c1/py-argv")"
else
  pass "the work order never reaches python3's argv"
fi

# ---------------------------------------------------------------------------
# 2. CONTROL — a first contact UNDER the threshold. It still splits (the
#    invocation is always its own paste), and still loads: this is the case that
#    always worked, pinned so the fix does not regress it.
# ---------------------------------------------------------------------------
c2="$STUBROOT/small"; mkdir -p "$c2"
NONCE2="abc123def4560002"
INVITE2="/hotline:hotline-ringing [CALL_ID: $NONCE2] [MODE: quick_call] [CALLER: /Users/x/proj] [SESSION: sess-2]"
printf '%s\nwhat is 2 + 2?\n' "$INVITE2" > "$c2/payload.md"
[[ "$(wc -c < "$c2/payload.md")" -lt 800 ]]
check "control fixture is under the collapse threshold" $? "bytes=$(wc -c < "$c2/payload.md")"

OUT2="$(run_paste "$c2" "$c2/payload.md" "$NONCE2")"
LOG2="$c2/sock/requests.log"

[[ "$(jq -r '.delivered' <<<"$OUT2" 2>/dev/null)" == "true" ]]
check "control first contact is delivered and confirmed" $? "out=$OUT2"

[[ "$(paste_count "$LOG2")" -eq 2 && "$(nth_paste "$LOG2" 1)" == "$INVITE2" ]]
check "control still isolates the invocation on paste 1" $? \
  "count=$(paste_count "$LOG2") paste1=$(nth_paste "$LOG2" 1)"

grep -qiE '(^| )(enter|return)( |$)' "$c2/sendkey" 2>/dev/null
check "control submits with a separate Enter keystroke" $? \
  "sendkey=$(cat "$c2/sendkey" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. GATING — a follow-up (NOT a slash command) must NOT split. The leading
#    [CALL_ID:] line is how a non-slash payload carries its nonce; it is not a
#    command, so one paste with its submit key and no separate Enter (the reuse
#    path's invariant).
# ---------------------------------------------------------------------------
c3="$STUBROOT/followup"; mkdir -p "$c3"
NONCE3="abc123def4560003"
printf '[CALL_ID: %s]\ncarry on with the plan\nsecond line of the message\n' "$NONCE3" > "$c3/payload.md"
OUT3="$(run_paste "$c3" "$c3/payload.md" "$NONCE3")"
LOG3="$c3/sock/requests.log"

[[ "$(jq -r '.delivered' <<<"$OUT3" 2>/dev/null)" == "true" ]]
check "non-slash follow-up is delivered" $? "out=$OUT3"

[[ "$(paste_count "$LOG3")" -eq 1 && "$(nth_paste "$LOG3" 1 submit_key)" == "return" ]]
check "non-slash follow-up is ONE paste, submit_key=return (no split)" $? \
  "count=$(paste_count "$LOG3") key=$(nth_paste "$LOG3" 1 submit_key)"

[[ ! -s "$c3/sendkey" ]]
check "non-slash follow-up sends no separate Enter" $? "sendkey=$(cat "$c3/sendkey" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 4. GATING — a single-line slash command with NO body must NOT split: nothing
#    to collapse, so one paste with its submit key.
# ---------------------------------------------------------------------------
c4="$STUBROOT/oneline"; mkdir -p "$c4"
NONCE4="abc123def4560004"
printf '/hotline:hotline-ringing [CALL_ID: %s] [MODE: quick_call] short question' "$NONCE4" > "$c4/payload.md"
OUT4="$(run_paste "$c4" "$c4/payload.md" "$NONCE4")"
LOG4="$c4/sock/requests.log"

[[ "$(jq -r '.delivered' <<<"$OUT4" 2>/dev/null)" == "true" ]]
check "single-line slash invocation is delivered" $? "out=$OUT4"

[[ "$(paste_count "$LOG4")" -eq 1 && "$(nth_paste "$LOG4" 1 submit_key)" == "return" ]]
check "single-line slash invocation is ONE paste, submit_key=return (no split)" $? \
  "count=$(paste_count "$LOG4") key=$(nth_paste "$LOG4" 1 submit_key)"

[[ ! -s "$c4/sendkey" ]]
check "single-line slash invocation sends no separate Enter" $? "sendkey=$(cat "$c4/sendkey" 2>/dev/null)"

# ---------------------------------------------------------------------------
[[ ! -s "$POISON_LOG" ]]
check "no test reached the real cmux or control socket" $? "$(cat "$POISON_LOG" 2>/dev/null)"

echo
echo "cmux-paste-slash-split: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || { printf '  - %s\n' "${FAILED_CASES[@]}"; exit 1; }
