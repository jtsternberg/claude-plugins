#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-reuse-surface.sh — verifies the follow-up is typed
# into the live REPL as TWO steps (literal text via `cmux send`, then submit via
# `cmux send-key Enter`) rather than a single `cmux send "$MSG\n"`. Bundling the
# newline into `send` does not submit against a bracketed-paste TUI REPL
# (claude-plugins-5zhp). We stub `cmux` on PATH to record the calls.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/cmux-reuse-surface.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

# --- Fake `cmux`: logs each invocation as one space-joined line, and returns a
#     non-empty screen for read-screen so the existence check passes. ----------
STUBDIR="$(mktemp -d)"
CALLLOG="$STUBDIR/calls.log"
# `printf %q` renders each arg shell-quoted on ONE line, so a bundled trailing
# newline shows up as a literal $'\n' token instead of silently wrapping.
cat > "$STUBDIR/cmux" <<STUB
#!/usr/bin/env bash
printf '%q ' "\$@" >> "$CALLLOG"; printf '\n' >> "$CALLLOG"
case "\$1" in
  read-screen) echo "live claude REPL screen"; exit 0 ;;
  *)           exit 0 ;;
esac
STUB
chmod +x "$STUBDIR/cmux"

OUT="$(PATH="$STUBDIR:$PATH" bash "$SCRIPT_UNDER_TEST" \
  --surface "w1:s1" --session "sess-123" --prompt "hello world" 2>&1)"

mapfile -t calls < "$CALLLOG"
LOG_VIEW="$(printf '%s\n' "${calls[@]}")"

# %q escapes spaces, so the message renders as e.g. `hello\ world` — match with
# globs that tolerate the escaping.
send_idx=-1; key_idx=-1; clear_idx=-1; i=0
for c in "${calls[@]}"; do
  case "$c" in
    # The clear is the raw Ctrl-C byte ($'\003'); %q renders it as $'\003'.
    "send --surface w1:s1 "*'\003'*)            clear_idx=$i ;;
    "send --surface w1:s1 "*hello*world*)       send_idx=$i ;;
    "send-key --surface w1:s1 Enter"*)          key_idx=$i ;;
  esac
  i=$((i + 1))
done

# A newline bundled into a `send` arg renders under %q as a literal \n token
# (either standalone $'\n' or trailing inside the message, e.g. world\n').
send_has_newline=false
grep -qE "^send .*\\\\n" "$CALLLOG" && send_has_newline=true

[[ $send_idx -ge 0 ]] && pass "message text sent via 'cmux send'" \
  || fail "message text sent via 'cmux send'" "log:"$'\n'"$LOG_VIEW"

[[ $key_idx -ge 0 ]] && pass "Enter submitted via 'cmux send-key Enter'" \
  || fail "Enter submitted via 'cmux send-key Enter'" "log:"$'\n'"$LOG_VIEW"

$send_has_newline \
  && fail "no trailing newline bundled into 'cmux send'" "the \\n-in-send regression is back" \
  || pass "no trailing newline bundled into 'cmux send'"

[[ $send_idx -ge 0 && $key_idx -gt $send_idx ]] \
  && pass "Enter is sent after the text" \
  || fail "Enter is sent after the text" "send_idx=$send_idx key_idx=$key_idx"

# The input box is cleared with a raw Ctrl-C byte BEFORE the message is typed, so
# leftover input can't get prepended to the follow-up (send-key ctrl+c does not
# reach an in-pane claude REPL — the raw byte via the text path does).
[[ $clear_idx -ge 0 ]] && pass "input box cleared with raw Ctrl-C (\$'\\003')" \
  || fail "input box cleared with raw Ctrl-C (\$'\\003')" "log:"$'\n'"$LOG_VIEW"

[[ $clear_idx -ge 0 && $send_idx -gt $clear_idx ]] \
  && pass "clear precedes the message text" \
  || fail "clear precedes the message text" "clear_idx=$clear_idx send_idx=$send_idx"

if [[ "$OUT" == *'"call_dir"'* ]]; then
  pass "emits call_dir JSON on success"
  cd="$(printf '%s' "$OUT" | sed -n 's/.*"call_dir": *"\([^"]*\)".*/\1/p')"
  [[ -n "$cd" && -d "$cd" ]] && rm -rf "$cd"
else
  fail "emits call_dir JSON on success" "out: $OUT"
fi

rm -rf "$STUBDIR"

echo ""
echo "cmux-reuse-surface: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
