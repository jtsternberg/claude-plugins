#!/usr/bin/env bash
# =============================================================================
# Regression tests for the shared per-call nonce helpers in repl-state.sh.
#
# WHY THESE EXIST: the mint-and-inject logic was copied into three delivery paths
# (cmux-call.sh, cmux-call-async.sh, cmux-reuse-surface.sh) and two of the copies
# split the prompt on the FIRST SPACE ANYWHERE in it:
#
#     CMD_TOKEN="${PROMPT%% *}"   REST="${PROMPT#* }"
#
# For a single-line `/hotline:hotline-ringing …` that happens to be right. For a
# MULTI-LINE prompt whose first line has no space — or any prompt where the first
# space falls on a later line — `%% *` reaches past the newline and the nonce gets
# spliced into the middle of line 2, where the receiver never finds it and the text
# is corrupted. A prompt starting with an absolute path (`/Users/JT/…`) was also
# treated as a slash command, splicing the nonce after the first directory.
#
# Both halves now live in repl-state.sh and every path calls them, so this suite is
# the one place that pins the rule. No cmux, no sockets, no processes.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/repl-state.sh
source "$HOTLINE_DIR/scripts/repl-state.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

assert_eq() {  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected: $(printf '%q' "$2")"$'\n'"       actual: $(printf '%q' "$3")"
  fi
}

echo "call-id injection:"
echo ""
echo "  -- minting --"

ID1=$(hotline_mint_call_id)
ID2=$(hotline_mint_call_id)
[[ "$ID1" =~ ^[0-9a-f]{16}$ ]] \
  && pass "a nonce is 16 lowercase hex characters" \
  || fail "a nonce is 16 lowercase hex characters" "got: $ID1"
[[ "$ID1" != "$ID2" ]] \
  && pass "two nonces differ (per-call, not per-session)" \
  || fail "two nonces differ (per-call, not per-session)" "both: $ID1"

echo ""
echo "  -- slash-command prompts: nonce INLINE after the command token --"
# claude parses a slash command only at the very start of the input, so a header
# line above /hotline:hotline-ringing turns the whole invocation into plain text.

assert_eq "single line: nonce lands after the command token" \
  '/hotline:hotline-ringing [CALL_ID: N] [MODE: work_order] do the thing' \
  "$(hotline_inject_call_id N '/hotline:hotline-ringing [MODE: work_order] do the thing')"

assert_eq "command token alone, no arguments" \
  '/hotline:ringing [CALL_ID: N]' \
  "$(hotline_inject_call_id N '/hotline:ringing')"

# THE BUG. `${PROMPT%% *}` reaches past the newline when the first line has no
# space, so the nonce landed inside line 2 — corrupting the text and hiding the
# nonce from the receiver.
assert_eq "multi-line, first line has NO space: nonce stays on line 1" \
  '/hotline:hotline-ringing [CALL_ID: N]
second line has spaces in it
third line' \
  "$(hotline_inject_call_id N '/hotline:hotline-ringing
second line has spaces in it
third line')"

assert_eq "multi-line with a space on line 1: only line 1 is touched" \
  '/hotline:hotline-ringing [CALL_ID: N] [MODE: work_order] first line
second line untouched' \
  "$(hotline_inject_call_id N '/hotline:hotline-ringing [MODE: work_order] first line
second line untouched')"

# A tab between the command and its arguments is still whitespace.
assert_eq "a tab after the command token splits there too" \
  "/hotline:ringing [CALL_ID: N]"$'\t'"tabbed args" \
  "$(hotline_inject_call_id N "/hotline:ringing"$'\t'"tabbed args")"

echo ""
echo "  -- everything else: nonce on its OWN leading line --"
# Its own line means it can never be broken across a rendered line wrap, which is
# what wait-for-response.sh matches on. Safe because the paste is atomic.

assert_eq "a plain single-line follow-up" \
  '[CALL_ID: N]
one more thing' \
  "$(hotline_inject_call_id N 'one more thing')"

assert_eq "a multi-line work order" \
  '[CALL_ID: N]
Step one
Step two' \
  "$(hotline_inject_call_id N 'Step one
Step two')"

# THE OTHER HALF OF THE BUG: a prompt opening with an absolute path is not a slash
# command, and splicing the nonce after its first directory component corrupted it.
assert_eq "an absolute path is NOT a slash command" \
  '[CALL_ID: N]
/Users/JT/Code/x is the file to read
second line' \
  "$(hotline_inject_call_id N '/Users/JT/Code/x is the file to read
second line')"

assert_eq "a bare / is not a command token either" \
  '[CALL_ID: N]
/ is the root directory' \
  "$(hotline_inject_call_id N '/ is the root directory')"

assert_eq "a path with no spaces is still not a command" \
  '[CALL_ID: N]
/etc/hosts' \
  "$(hotline_inject_call_id N '/etc/hosts')"

echo ""
echo "  -- the payload survives verbatim --"

# Whatever the placement, every byte of the original must still be there. A
# work-order-shaped payload with the characters that have bitten this transport
# before: backslash sequences, dollars, backticks, quotes, a trailing newline.
HAIRY='Step one: audit `dial.sh` for $DOLLAR and "quotes"
Step two: note the literal \n \r \t sequences
Step three: report back
'
# Compared through FILES, not `$(…)`: command substitution strips trailing
# newlines, and the callers all redirect straight to a file — so a byte comparison
# has to go the same way or it cannot see the last byte at all.
HAIRY_EXPECT="$(mktemp)"; HAIRY_ACTUAL="$(mktemp)"
printf '[CALL_ID: N]\n%s' "$HAIRY" > "$HAIRY_EXPECT"
hotline_inject_call_id N "$HAIRY" > "$HAIRY_ACTUAL"
if cmp -s "$HAIRY_EXPECT" "$HAIRY_ACTUAL"; then
  pass "a payload with backslashes, dollars, backticks and a trailing newline is untouched"
else
  fail "a payload with backslashes, dollars, backticks and a trailing newline is untouched" \
       "$(diff <(od -c "$HAIRY_EXPECT") <(od -c "$HAIRY_ACTUAL") | head -6)"
fi
rm -f "$HAIRY_EXPECT" "$HAIRY_ACTUAL"

SLASHY="/hotline:hotline-ringing [MODE: x] $HAIRY"
OUT_SLASHY="$(hotline_inject_call_id N "$SLASHY")"
[[ "$OUT_SLASHY" == "/hotline:hotline-ringing [CALL_ID: N] [MODE: x] "* ]] \
  && [[ "$OUT_SLASHY" == *"Step three: report back"* ]] \
  && pass "the same payload behind a slash command keeps its body intact" \
  || fail "the same payload behind a slash command keeps its body intact" \
          "got: $(printf '%q' "$OUT_SLASHY")"

# The nonce must appear exactly once, whichever branch ran.
for probe in '/hotline:ringing args here' 'plain message' '/Users/x/y z'; do
  COUNT=$(hotline_inject_call_id NONCEXYZ "$probe" | grep -c 'NONCEXYZ' || true)
  [[ "$COUNT" -eq 1 ]] \
    && pass "the nonce appears exactly once for: ${probe:0:24}" \
    || fail "the nonce appears exactly once for: ${probe:0:24}" "count=$COUNT"
done

echo ""
echo "  -- every delivery path uses the shared helpers --"
# The point of extracting them. A path that re-grows its own copy is how the two
# broken variants came to exist in the first place.
for f in cmux-call.sh cmux-call-async.sh cmux-reuse-surface.sh; do
  SRC="$HOTLINE_DIR/skills/dial/scripts/$f"
  grep -q 'hotline_mint_call_id' "$SRC" \
    && pass "$f mints via the shared helper" \
    || fail "$f mints via the shared helper" "no hotline_mint_call_id in $f"
  if grep -qE '\$\{PROMPT%% \*\}|CMD_TOKEN=' "$SRC"; then
    fail "$f has no local copy of the split logic" "the first-space split is back in $f"
  else
    pass "$f has no local copy of the split logic"
  fi
done

echo ""
echo "  -- the slash-command predicate is single-sourced --"
# Inline nonce placement (repl-state.sh) and split-paste delivery (cmux-paste.sh)
# turn on the SAME "is the first line a slash command?" judgement. It lives in one
# predicate so the two can never disagree; a private regex copy in cmux-paste.sh is
# exactly the drift this guards (claude-plugins-pmgb review).
PASTE_SRC="$HOTLINE_DIR/skills/dial/scripts/cmux-paste.sh"
grep -q 'hotline_is_slash_command_first_line' "$PASTE_SRC" \
  && pass "cmux-paste.sh decides the split via the shared predicate" \
  || fail "cmux-paste.sh decides the split via the shared predicate" \
          "no hotline_is_slash_command_first_line call in cmux-paste.sh"
if grep -qE '\^/\[A-Za-z0-9\]' "$PASTE_SRC"; then
  fail "cmux-paste.sh has no local copy of the slash-command regex" \
       "the ^/[A-Za-z0-9] regex is back in cmux-paste.sh"
else
  pass "cmux-paste.sh has no local copy of the slash-command regex"
fi
REGEX_HITS=$(grep -cE '\^/\[A-Za-z0-9\]\[A-Za-z0-9:._-\]' "$HOTLINE_DIR/scripts/repl-state.sh" || true)
[[ "$REGEX_HITS" -eq 1 ]] \
  && pass "the slash-command regex is defined exactly once, in repl-state.sh" \
  || fail "the slash-command regex is defined exactly once, in repl-state.sh" "hits=$REGEX_HITS"

echo ""
echo "call-id injection: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
