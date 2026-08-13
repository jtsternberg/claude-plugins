#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-paste.sh's PARKED-PAYLOAD retry (claude-plugins-fkgv).
#
# terminal.paste submit_key:return intermittently (~5% in live repro, on a
# multi-line payload that collapses to a placeholder) fails to submit — the
# injected return races the paste render and is dropped, leaving the payload
# parked in the input box. cmux-paste.sh now fires ONE `cmux send-key Enter` when
# it detects that parked state, then re-verifies, before calling the delivery lost.
#
# The double-submit guard is the whole risk surface, so it gets a case per shape:
#   parked          → retry → confirmed          (the fix works)
#   parked          → retry → still parked        → stage-deliver error (honest)
#   already submitted (nonce in transcript)      → NO retry
#   busy / queued (phase-2 shapes)               → NO retry
#   ghost suggested-prompt in the box (ff6g)     → NO retry (not our payload)
#
# `cmux` is a PATH stub whose read-screen SEQUENCES: the first read (box-wait /
# baseline) returns a clean empty box, later reads return the case screen — so a
# screen marker only counts if it appeared AFTER the paste, exactly as the real
# confirmation's recency baseline requires. send-key is logged; for the one case
# that models a successful retry, an Enter appends the nonce to the transcript and
# empties the box. $CMUX_SOCKET_PATH points at the shared python socket stub.
# =============================================================================
set -u

PASS=0; FAIL=0; FAILED_CASES=()
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$HOTLINE_DIR/skills/dial/scripts/cmux-paste.sh"
REAL_PYTHON3="$(command -v python3)"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

if [[ -z "$REAL_PYTHON3" ]]; then
  echo "cmux-paste-parked-retry: SKIP — python3 not available"; exit 0
fi

GLYPH=$'\xe2\x9d\xaf'; NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"
SURF_UUID="aaaa0000-1111-4111-8111-111111111111"
WS_UUID="bbbb0000-2222-4222-8222-222222222222"

STUBROOT="$(mktemp -d)"
POISON_LOG="$STUBROOT/violations"
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
trap 'socket_stub_cleanup; rm -rf "$STUBROOT"' EXIT
socket_stub_write_responses "$STUBROOT/responses"
OK_RESPONSES="$STUBROOT/responses/ok.json"

export HOTLINE_PASTE_CONFIRM_TRIES=2
export HOTLINE_PASTE_CONFIRM_SLEEP=0.05

empty_box() { printf '%s\n%s%s\n%s\n' "$RULE" "$GLYPH" "$NBSP" "$RULE"; }
box_holding() { printf '%s\n%s%s%s\n%s\n' "$RULE" "$GLYPH" "$NBSP" "$1" "$RULE"; }
queued_screen() { printf '%s%s prior\n\n%s Working… (5s · ↓ 12 tokens)\n%s\n%s%s\n%s\nPress up to edit queued messages\n' \
  "$GLYPH" " " "✶" "$RULE" "$GLYPH" "$NBSP" "$RULE"; }
# A reused surface whose scrollback ALREADY shows a prior collapsed paste (so
# "[Pasted text" is not fresh vs baseline), with an EMPTY box — the pre-paste state
# of the observed fkgv instance (the '#2' index implies a submitted '#1' above).
collapsed_baseline() { printf '%s%s [Pasted text #1 +5 lines]\n%s\n%s%s\n%s\n' \
  "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"; }
# Same surface after a paste that PARKED: the new collapsed placeholder sits in the
# box, the nonce is not visible, and the stale '#1' is still in scrollback.
collapsed_parked() { printf '%s%s [Pasted text #1 +5 lines]\n%s\n%s%s[Pasted text #2 +6 lines]\n%s\n' \
  "$GLYPH" " " "$RULE" "$GLYPH" "$NBSP" "$RULE"; }

# make_cmux <bindir> <baseline-file> <target-file> <counter> <sendkey-log> <transcript> <submit-on-enter>
make_cmux() {
  local bindir="$1" base="$2" tgt="$3" cnt="$4" sk="$5" tr="$6" submit="$7"
  mkdir -p "$bindir"; echo 0 > "$cnt"
  cat > "$bindir/cmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  read-screen)
    n=\$(cat "$cnt" 2>/dev/null || echo 0)
    if [[ "\$n" -lt 1 ]]; then cat "$base"; else cat "$tgt"; fi
    echo \$((n+1)) > "$cnt"
    exit 0 ;;
  send-key)
    echo "\$*" >> "$sk"
    if [[ "$submit" == "yes" ]] && printf '%s' "\$*" | grep -qiE '(enter|return)'; then
      printf '{"type":"user","nonce":"%s"}\n' "\$HOTLINE_TEST_NONCE" >> "$tr"
      printf '%s\n%s%s\n%s\n' '$RULE' '$GLYPH' '$NBSP' '$RULE' > "$tgt"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bindir/cmux"
}

# run_case <dir> <call-id> <target-screen> <transcript-seed> <submit-on-enter> [baseline-screen]
#   plants transcript + baseline/target screens, runs cmux-paste.sh, echoes JSON.
run_case() {
  local dir="$1" cid="$2" target="$3" seed="$4" submit="$5" baseline="${6:-$(empty_box)}"
  local bin="$dir/bin" home="$dir/home" sock proj
  mkdir -p "$dir/cwd" "$home"
  SENDKEY_LOG="$dir/sendkey"; : > "$SENDKEY_LOG"
  printf '%s' "$baseline" > "$dir/baseline"
  printf '%s' "$target" > "$dir/target"
  # plant the transcript where transcript-path.sh (under this HOME) will look
  proj=$(HOME="$home" bash "$HOTLINE_DIR/scripts/transcript-path.sh" --cwd "$dir/cwd" --session "sess-$cid" 2>/dev/null)
  [[ -n "$proj" ]] && { mkdir -p "$(dirname "$proj")"; printf '%s' "$seed" > "$proj"; }
  make_cmux "$bin" "$dir/baseline" "$dir/target" "$dir/cnt" "$SENDKEY_LOG" "$proj" "$submit"
  write_python3_shim "$bin" "$dir/py-argv"
  sock="$(socket_stub_start "$dir/sock" "$OK_RESPONSES" "$dir/echo-unused")"
  printf '[CALL_ID: %s]\nline one\nline two\nline three\nline four\nline five\n' "$cid" > "$dir/payload.md"
  HOME="$home" HOTLINE_TEST_NONCE="$cid" PATH="$bin:$PATH" CMUX_SOCKET_PATH="$sock" \
    bash "$SCRIPT_UNDER_TEST" --surface "$SURF_UUID" --workspace "$WS_UUID" \
      --payload-file "$dir/payload.md" --call-id "$cid" \
      --cwd "$dir/cwd" --session "sess-$cid" --wait-box 3 2>/dev/null
}

echo "cmux-paste.sh parked-payload retry:"

# 1. PARKED (collapsed, screen tier CANNOT confirm) → retry → confirmed.
#    baseline already shows a prior collapsed paste, so "[Pasted text" is not fresh
#    and the nonce is hidden inside the placeholder — exactly the observed instance.
c1="$STUBROOT/parked-ok"; N1="park0000000000a1"
OUT1=$(run_case "$c1" "$N1" "$(collapsed_parked)" "" yes "$(collapsed_baseline)")
[[ "$(jq -r '.delivered' <<<"$OUT1" 2>/dev/null)" == "true" \
   && "$(jq -r '.retried_enter' <<<"$OUT1" 2>/dev/null)" == "true" ]]
check "parked payload → delivered:true, retried_enter:true" $? "out=$OUT1"
[[ "$(grep -ciE 'enter|return' "$c1/sendkey")" -eq 1 ]]
check "parked payload → exactly ONE Enter fired" $? "sendkey=$(cat "$c1/sendkey")"

# 2. PARKED → retry Enter does NOT submit → still parked → stage-deliver error.
c2="$STUBROOT/parked-fail"; N2="park0000000000a2"
OUT2=$(run_case "$c2" "$N2" "$(collapsed_parked)" "" no "$(collapsed_baseline)")
[[ "$(jq -r '.delivered' <<<"$OUT2" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$OUT2" 2>/dev/null)" == "true" ]]
check "parked + retry fails → delivered:false sent:true (stage deliver)" $? "out=$OUT2"
[[ "$(grep -ciE 'enter|return' "$c2/sendkey")" -eq 1 ]]
check "parked + retry fails → still fired exactly ONE Enter (not a loop)" $? "sendkey=$(cat "$c2/sendkey")"

# 3. ALREADY SUBMITTED (nonce in transcript) → NO retry.
c3="$STUBROOT/submitted"; N3="park0000000000a3"
OUT3=$(run_case "$c3" "$N3" "$(empty_box)" "{\"type\":\"user\",\"nonce\":\"$N3\"}" no)
[[ "$(jq -r '.delivered' <<<"$OUT3" 2>/dev/null)" == "true" \
   && "$(jq -r '.retried_enter' <<<"$OUT3" 2>/dev/null)" == "false" ]]
check "already-submitted → delivered:true, retried_enter:false" $? "out=$OUT3"
[[ ! -s "$c3/sendkey" ]]
check "already-submitted → NO Enter (double-submit guard)" $? "sendkey=$(cat "$c3/sendkey")"

# 4. BUSY / QUEUED → NO retry (submitted, per phase-2).
c4="$STUBROOT/busy"; N4="park0000000000a4"
OUT4=$(run_case "$c4" "$N4" "$(queued_screen)" "" no)
[[ "$(jq -r '.delivered' <<<"$OUT4" 2>/dev/null)" == "true" \
   && "$(jq -r '.retried_enter' <<<"$OUT4" 2>/dev/null)" == "false" ]]
check "busy/queued → confirmed without retry" $? "out=$OUT4"
[[ ! -s "$c4/sendkey" ]]
check "busy/queued → NO Enter" $? "sendkey=$(cat "$c4/sendkey")"

# 5. GHOST suggested-prompt in the box (ff6g) → NO retry, NO phantom submit.
c5="$STUBROOT/ghost"; N5="park0000000000a5"
OUT5=$(run_case "$c5" "$N5" "$(box_holding "push it")" "" no)
[[ "$(jq -r '.delivered' <<<"$OUT5" 2>/dev/null)" == "false" ]]
check "ghost box text → delivery not faked" $? "out=$OUT5"
[[ ! -s "$c5/sendkey" ]]
check "ghost box text → NO Enter (no phantom submit, ff6g-safe)" $? "sendkey=$(cat "$c5/sendkey")"

[[ ! -s "$POISON_LOG" ]]
check "no test reached the real cmux or control socket" $? "$(cat "$POISON_LOG" 2>/dev/null)"

echo
echo "cmux-paste-parked-retry: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || { printf '  - %s\n' "${FAILED_CASES[@]}"; exit 1; }
