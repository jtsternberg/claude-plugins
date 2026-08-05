#!/usr/bin/env bash
# =============================================================================
# Regression tests for cmux-reuse-surface.sh. Three behaviors are pinned here:
#
#   1. TWO-STEP SUBMIT — the follow-up is typed as literal text via `cmux send`,
#      then submitted via `cmux send-key Enter`. Bundling the newline into the
#      `send` does not submit against a bracketed-paste TUI REPL
#      (claude-plugins-5zhp).
#
#   2. LITERAL PAYLOAD DELIVERY (claude-plugins-nofy) — `cmux send` interprets
#      the two-character sequences \n, \r and \t in its text argument and has NO
#      backslash escape (verified live on cmux 0.64.20: `\\` arrives as TWO
#      backslashes, `\\n` as one backslash + Enter). So a payload containing
#      those sequences must be SPLIT across several `send` calls such that no
#      single argument contains one, and the concatenation must reproduce the
#      payload byte for byte.
#
#   3. CONDITIONAL INPUT-BOX CLEAR (claude-plugins-06ws) — the raw Ctrl-C byte
#      is sent ONLY when the REPL's input box visibly holds unsent text AND the
#      REPL shows no sign of an active turn. Into a busy REPL, or an interrupted
#      one, or one whose box would not clear, the script must not send text at
#      all — it returns the fresh-surface fallback.
#
# `cmux` is stubbed on PATH. read-screen serves a scripted sequence of fixture
# screens (one per call, holding on the last), so a test can stage "parked then
# clean" or "changing while busy". Nothing here touches a real cmux or REPL.
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

# The live input box pads its ❯ glyph with a NO-BREAK SPACE; the transcript
# echoes of prior user turns use a plain space. Both shapes appear in the
# fixtures below so the "which ❯ line is the live box" logic gets exercised.
GLYPH=$'\xe2\x9d\xaf'
NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"

STUBROOT="$(mktemp -d)"
trap 'rm -rf "$STUBROOT"' EXIT

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

# --- Stub harness ----------------------------------------------------------
# run_case <name> -- <screen-fn>... -- [extra args to the script under test]
# Sets: OUT, CALLLOG (one %q-quoted line per cmux invocation), SENDTEXTS
# (NUL-separated final argument of every `cmux send`).
CASEDIR=""
OUT=""
CALLLOG=""
SENDTEXT=""
declare -a SENDTEXTS=()

run_case() {
  local name="$1"; shift
  local -a screens=() extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do screens+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  extra=("$@")

  CASEDIR="$STUBROOT/$name"
  mkdir -p "$CASEDIR/screens"
  CALLLOG="$CASEDIR/calls.log"
  SENDTEXT="$CASEDIR/sendtext.log"
  : > "$CALLLOG"; : > "$SENDTEXT"

  local i=1 fn
  for fn in "${screens[@]}"; do
    "$fn" > "$CASEDIR/screens/$i.txt"
    i=$((i + 1))
  done
  echo $((i - 1)) > "$CASEDIR/screens/count"
  echo 0 > "$CASEDIR/screens/cursor"

  cat > "$CASEDIR/cmux" <<'STUB'
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
    cat "$STUB_SCREENS/$c.txt"
    exit 0
    ;;
  send)
    # Record the payload (last arg) raw and NUL-terminated so the test can
    # reassemble it without fighting shell quoting.
    printf '%s\0' "${@: -1}" >> "$STUB_SENDTEXT"
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$CASEDIR/cmux"

  OUT="$(STUB_CALLLOG="$CALLLOG" STUB_SENDTEXT="$SENDTEXT" STUB_SCREENS="$CASEDIR/screens" \
    PATH="$CASEDIR:$PATH" bash "$SCRIPT_UNDER_TEST" \
    --surface "w1:s1" --session "sess-123" "${extra[@]}" 2>&1)"

  SENDTEXTS=()
  while IFS= read -r -d '' t; do SENDTEXTS+=("$t"); done < "$SENDTEXT"

  # Any call_dir the script created is a temp dir; clean up as we go.
  local cd_path
  cd_path="$(printf '%s' "$OUT" | sed -n 's/.*"call_dir": *"\([^"]*\)".*/\1/p')"
  [[ -n "$cd_path" && -d "$cd_path" ]] && rm -rf "$cd_path"
  return 0
}

log_view() { cat "$CALLLOG"; }

# Count `cmux send` calls whose payload is the raw Ctrl-C byte.
clear_count() { grep -cE "^send .*\\\$'\\\\003'" "$CALLLOG" || true; }
# Index (0-based) of the first Ctrl-C send in the call log, or -1.
clear_index() {
  local i=0 line
  while IFS= read -r line; do
    [[ "$line" == "send "*'$\047\003\047'* ]] && { echo "$i"; return; }
    case "$line" in
      send*\$\'\\003\'*) echo "$i"; return ;;
    esac
    i=$((i + 1))
  done < "$CALLLOG"
  echo -1
}
# Index of the first send-key Enter, or -1.
enter_index() {
  local i=0 line
  while IFS= read -r line; do
    case "$line" in
      send-key*Enter*) echo "$i"; return ;;
    esac
    i=$((i + 1))
  done < "$CALLLOG"
  echo -1
}
# The message the REPL would end up with: every non-Ctrl-C send payload, joined.
assembled() {
  local out="" t
  for t in "${SENDTEXTS[@]:-}"; do
    [[ "$t" == $'\003' ]] && continue
    out+="$t"
  done
  printf '%s' "$out"
}

echo "cmux-reuse-surface"
echo ""
echo "  -- literal payload delivery (nofy) --"

# --- A payload with no backslash-escape sequences goes in ONE send. ----------
run_case plain screen_idle_empty -- --prompt "hello world"
texts=(); for t in "${SENDTEXTS[@]:-}"; do [[ "$t" == $'\003' ]] || texts+=("$t"); done
if [[ ${#texts[@]} -eq 1 ]]; then
  pass "plain payload is sent as a single 'cmux send'"
else
  fail "plain payload is sent as a single 'cmux send'" "sends: ${#texts[@]}"
fi
[[ "$(assembled)" == *"hello world"* ]] \
  && pass "plain payload arrives intact" \
  || fail "plain payload arrives intact" "assembled: $(assembled)"

# --- CANARY: a literal backslash-n must survive to the REPL. ----------------
CANARY='docs say "\n and \r send Enter" and \t sends Tab'
run_case canary screen_idle_empty -- --prompt "$CANARY"
asm="$(assembled)"
[[ "$asm" == *"$CANARY"* ]] \
  && pass "payload containing literal \\n \\r \\t reassembles byte-for-byte" \
  || fail "payload containing literal \\n \\r \\t reassembles byte-for-byte" "assembled: $asm"

bad=""
for t in "${SENDTEXTS[@]:-}"; do
  [[ "$t" == $'\003' ]] && continue
  case "$t" in
    *\\n*|*\\r*|*\\t*) bad="$t"; break ;;
  esac
done
[[ -z "$bad" ]] \
  && pass "no single 'cmux send' argument carries a \\n/\\r/\\t sequence" \
  || fail "no single 'cmux send' argument carries a \\n/\\r/\\t sequence" "arg: $bad"

# --- Doubled backslashes must not be collapsed or expanded. -----------------
DOUBLED='path C:\\name and a bare trailing \'
run_case doubled screen_idle_empty -- --prompt "$DOUBLED"
asm="$(assembled)"
[[ "$asm" == *"$DOUBLED"* ]] \
  && pass "doubled and trailing backslashes survive unchanged" \
  || fail "doubled and trailing backslashes survive unchanged" "assembled: $asm"
bad=""
for t in "${SENDTEXTS[@]:-}"; do
  [[ "$t" == $'\003' ]] && continue
  case "$t" in *\\n*|*\\r*|*\\t*) bad="$t"; break ;; esac
done
[[ -z "$bad" ]] \
  && pass "doubled-backslash payload still splits away every \\n sequence" \
  || fail "doubled-backslash payload still splits away every \\n sequence" "arg: $bad"

# --- A real newline must never be bundled into a send. ----------------------
run_case newline screen_idle_empty -- --prompt "hello world"
if grep -qE "^send .*\\\\n" "$CALLLOG"; then
  fail "no trailing newline bundled into 'cmux send'" "the \\n-in-send regression is back"
else
  pass "no trailing newline bundled into 'cmux send'"
fi

echo ""
echo "  -- conditional input-box clear (06ws) --"

# --- Idle + empty box: no clear at all, message goes through. ---------------
run_case idle_empty screen_idle_empty -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "idle REPL with an empty box gets NO Ctrl-C" \
  || fail "idle REPL with an empty box gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "idle REPL with an empty box: emits call_dir" \
  || fail "idle REPL with an empty box: emits call_dir" "out: $OUT"

# --- Empty box on a never-used REPL: the placeholder is not parked text. ----
run_case placeholder screen_placeholder -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "placeholder hint is not mistaken for parked text" \
  || fail "placeholder hint is not mistaken for parked text" "log:"$'\n'"$(log_view)"

# --- Busy + empty box: still no clear, and the message is still sent. -------
#     Text+Enter into a busy REPL is enqueued and delivered; the destructive
#     thing is the interrupt, so it is the interrupt we withhold.
run_case busy_empty screen_busy_empty -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "busy REPL with an empty box gets NO Ctrl-C" \
  || fail "busy REPL with an empty box gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "busy REPL with an empty box: message still sent, emits call_dir" \
  || fail "busy REPL with an empty box: message still sent, emits call_dir" "out: $OUT"

# --- Idle + parked text: clear, confirm it took, then send. -----------------
run_case parked_clears screen_idle_parked screen_idle_parked screen_idle_empty -- --prompt "follow up"
[[ "$(clear_count)" -ge 1 ]] \
  && pass "idle REPL with parked text IS cleared" \
  || fail "idle REPL with parked text IS cleared" "log:"$'\n'"$(log_view)"
ci="$(clear_index)"; msg_i=-1; i=0
while IFS= read -r line; do
  case "$line" in send*follow*up*) msg_i=$i; break ;; esac
  i=$((i + 1))
done < "$CALLLOG"
[[ "$ci" -ge 0 && "$msg_i" -gt "$ci" ]] \
  && pass "the clear precedes the message text" \
  || fail "the clear precedes the message text" "clear=$ci msg=$msg_i"
[[ "$OUT" == *'"call_dir"'* ]] \
  && pass "cleared box: emits call_dir" \
  || fail "cleared box: emits call_dir" "out: $OUT"

# --- Idle + parked text that will not clear: fall back, send nothing. -------
run_case parked_sticks screen_idle_parked screen_idle_parked screen_idle_parked -- --prompt "follow up"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "a box that will not clear returns the fresh-surface fallback" \
  || fail "a box that will not clear returns the fresh-surface fallback" "out: $OUT"
if printf '%s' "$(assembled)" | grep -q "follow up"; then
  fail "a box that will not clear never receives the message" "it was sent anyway"
else
  pass "a box that will not clear never receives the message"
fi

# --- Busy + parked text: no clear, no send, fall back. ----------------------
run_case busy_parked screen_busy_parked screen_busy_parked -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "busy REPL with parked text gets NO Ctrl-C" \
  || fail "busy REPL with parked text gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "busy REPL with parked text returns the fresh-surface fallback" \
  || fail "busy REPL with parked text returns the fresh-surface fallback" "out: $OUT"
if printf '%s' "$(assembled)" | grep -q "follow up"; then
  fail "busy REPL with parked text never receives the message" "it was sent anyway"
else
  pass "busy REPL with parked text never receives the message"
fi

# --- Parked text on a REPL with no spinner but a changing screen. -----------
run_case parked_moving screen_parked_moving_a screen_parked_moving_b -- --prompt "follow up"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "a changing screen counts as busy: no Ctrl-C" \
  || fail "a changing screen counts as busy: no Ctrl-C" "log:"$'\n'"$(log_view)"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "a changing screen with parked text returns the fallback" \
  || fail "a changing screen with parked text returns the fallback" "out: $OUT"

# --- Interrupted REPL: send nothing, fall back (06ws acceptance criteria). --
run_case interrupted screen_interrupted -- --prompt "follow up"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "an interrupted REPL returns the fresh-surface fallback, not exit 0 success" \
  || fail "an interrupted REPL returns the fresh-surface fallback, not exit 0 success" "out: $OUT"
[[ "$(clear_count)" -eq 0 ]] \
  && pass "an interrupted REPL gets NO Ctrl-C" \
  || fail "an interrupted REPL gets NO Ctrl-C" "log:"$'\n'"$(log_view)"
if printf '%s' "$(assembled)" | grep -q "follow up"; then
  fail "an interrupted REPL never receives the message" "it was sent anyway"
else
  pass "an interrupted REPL never receives the message"
fi

echo ""
echo "  -- submit contract --"

# --- Enter is a send-key, and it comes after every text chunk. --------------
run_case submit screen_idle_empty -- --prompt "$CANARY"
ei="$(enter_index)"
[[ "$ei" -ge 0 ]] \
  && pass "Enter submitted via 'cmux send-key Enter'" \
  || fail "Enter submitted via 'cmux send-key Enter'" "log:"$'\n'"$(log_view)"
last_send=-1; i=0
while IFS= read -r line; do
  case "$line" in send\ *) last_send=$i ;; esac
  i=$((i + 1))
done < "$CALLLOG"
[[ "$ei" -gt "$last_send" && "$last_send" -ge 0 ]] \
  && pass "Enter comes after the LAST text chunk" \
  || fail "Enter comes after the LAST text chunk" "enter=$ei last_send=$last_send"

# --- Surface gone → fallback, and nothing typed anywhere. ------------------
CASEDIR="$STUBROOT/gone"; mkdir -p "$CASEDIR"
CALLLOG="$CASEDIR/calls.log"; SENDTEXT="$CASEDIR/sendtext.log"
: > "$CALLLOG"; : > "$SENDTEXT"
cat > "$CASEDIR/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CALLLOG"; printf '\n' >> "$STUB_CALLLOG"
case "$1" in
  read-screen) echo "Error: surface not found" >&2; exit 1 ;;
  send) printf '%s\0' "${@: -1}" >> "$STUB_SENDTEXT"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$CASEDIR/cmux"
OUT="$(STUB_CALLLOG="$CALLLOG" STUB_SENDTEXT="$SENDTEXT" PATH="$CASEDIR:$PATH" \
  bash "$SCRIPT_UNDER_TEST" --surface "w1:s1" --prompt "follow up" 2>&1)"
[[ "$OUT" == *'"fallback"'* ]] \
  && pass "a dead surface returns the fresh-surface fallback" \
  || fail "a dead surface returns the fresh-surface fallback" "out: $OUT"
[[ ! -s "$SENDTEXT" ]] \
  && pass "a dead surface receives no text at all" \
  || fail "a dead surface receives no text at all" "sent: $(tr '\0' '|' < "$SENDTEXT")"

echo ""
echo "cmux-reuse-surface: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
