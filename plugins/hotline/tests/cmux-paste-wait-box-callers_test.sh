#!/usr/bin/env bash
# =============================================================================
# --wait-box IS A FRESH-SURFACE FLAG. cmux-paste.sh's box gate checks the startup
# trust dialog only when NO input box is drawn, on the grounds that a live box
# proves the REPL is past that gate. That is true of a surface this dial just
# opened. It is NOT true of a REUSED one: a previous exchange's box render sits 6
# rows above a live 5-line trust dialog, both fit the 12-row tail the gate reads,
# box-first wins, and the payload is pasted into the dialog — whose default option
# is `No, exit`.
#
# Nothing in cmux-paste.sh can tell the two apart, so the safety of that ordering
# is an invariant of its CALLERS, and this is what holds it: every --wait-box
# caller opens the surface first, and the reuse path passes none. If a reuse-path
# caller ever needs --wait-box, the gate has to check the dialog first for it.
#
# Source: claude-plugins-fr46 (PR #22 fix-verifier §3).
# =============================================================================
set -u

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/dial/scripts" && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; printf '      %s\n' "${2:-}"; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

echo "cmux-paste.sh --wait-box callers:"

# The reuse path. It is the ONE script that pastes into a surface it did not open,
# so it is the one that must never pass the flag. Comment lines are stripped first:
# the file documents the absence, and the documentation must not read as the code.
REUSE="$SCRIPTS/cmux-reuse-surface.sh"
[[ -f "$REUSE" ]]
check "cmux-reuse-surface.sh is where this suite expects it" $? "not found: $REUSE"
REUSE_CODE=$(sed 's/#.*$//' "$REUSE")
if grep -q -- '--wait-box' <<<"$REUSE_CODE"; then
  fail "the reuse path passes NO --wait-box (its surface is not fresh)" \
    "$(grep -n -- '--wait-box' <<<"$REUSE_CODE")"
else
  pass "the reuse path passes NO --wait-box (its surface is not fresh)"
fi

# And nothing ELSE grows a reuse-path caller. Every script that passes the flag is
# named here with the surface it opened first; a new name in this list is a change
# that has to be read against the gate's ordering, not waved through.
EXPECTED="cmux-call.sh dial.sh"
ACTUAL=""
for f in "$SCRIPTS"/*.sh; do
  b=$(basename "$f")
  [[ "$b" == "cmux-paste.sh" ]] && continue
  grep -q -- '--wait-box' <<<"$(sed 's/#.*$//' "$f")" && ACTUAL+="$b "
done
ACTUAL=$(printf '%s' "$ACTUAL" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//')
[[ "$ACTUAL" == "$EXPECTED" ]]
check "only fresh-surface callers pass --wait-box ($EXPECTED)" $? \
  "found: ${ACTUAL:-none}"

# The positive control: this suite can actually SEE the flag. Without it a typo in
# the pattern reads as "no caller passes --wait-box" and the whole file passes on a
# scan that never matched anything.
grep -q -- '--wait-box' <<<"$(sed 's/#.*$//' "$SCRIPTS/cmux-call.sh")"
check "…and the scan is proved able to match: cmux-call.sh passes it" $? \
  "the pattern matched nothing in a file that does pass --wait-box"

# The gate itself still orders box before dialog. If that flips, the invariant this
# suite holds stops being load-bearing and the comment above it goes stale.
BOX_LINE=$(grep -n 'repl_box_present "\$BOX_WINDOW"' "$SCRIPTS/cmux-paste.sh" | head -1 | cut -d: -f1)
DIALOG_LINE=$(grep -n 'repl_trust_dialog_present "\$BOX_WINDOW"' "$SCRIPTS/cmux-paste.sh" | head -1 | cut -d: -f1)
[[ -n "$BOX_LINE" && -n "$DIALOG_LINE" && "$BOX_LINE" -lt "$DIALOG_LINE" ]]
check "the box gate still checks the box BEFORE the dialog (what makes this invariant matter)" $? \
  "box at ${BOX_LINE:-none}, dialog at ${DIALOG_LINE:-none}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
