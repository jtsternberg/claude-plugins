#!/usr/bin/env bash
# =============================================================================
# scripts/status-classes.sh — the STATUS word → class map every STATUS parser
# reads: built-in defaults, a call's declarations, and refusal of bad ones.
# =============================================================================
set -u
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT=${TMP_ROOT%/}
HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/status-classes.sh
source "$HOTLINE_DIR/scripts/status-classes.sh"
PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }
D=$(mktemp -d "$TMP_ROOT"/hotline-status-classes-XXXXXX); trap 'rm -rf "$D"' EXIT

echo "status-classes.sh:"

for pair in DONE=done WORK_COMPLETE=done OUT_OF_SCOPE=out_of_scope AWAITING_REVIEW=awaiting_review BLOCKED=blocked; do
  [[ "$(hotline_status_class "${pair%%=*}" "")" == "${pair#*=}" ]]
  check "built-in ${pair%%=*} is ${pair#*=} with no call map" $?
done
[[ "$(hotline_status_class NEEDS_OVERSEER "")" == unknown ]]
check "an undeclared word is unknown" $?
[[ "$(hotline_status_class WORK_IN_PROGRESS "")" == unknown ]]
check "WORK_IN_PROGRESS has no class" $?

out=$(hotline_status_classes_parse "NEEDS_OVERSEER=blocked, SHIPPED=done" "PARKED=awaiting_review")
[[ "$out" == $'NEEDS_OVERSEER=blocked\nSHIPPED=done\nPARKED=awaiting_review' ]]
check "a declaration list (commas, spaces, several args) normalizes to WORD=class lines" $? "out=[$out]"
out=$(hotline_status_classes_parse "FOO=done FOO=blocked")
[[ "$out" == "FOO=blocked" ]]
check "a later declaration of the same word wins" $? "out=[$out]"
for bad in "needs=blocked" "FOO" "FOO=stuck" "WORK_IN_PROGRESS=done" "FOO*=done"; do
  out=$(hotline_status_classes_parse "$bad" 2>"$D/err"); rc=$?
  [[ $rc -ne 0 && -z "$out" && -s "$D/err" ]]
  check "'$bad' is refused with a reason" $? "rc=$rc out=[$out]"
done
[[ -z "$(hotline_status_classes_parse "")" ]]
check "an empty declaration list is empty" $?

printf 'NEEDS_OVERSEER=blocked\nBLOCKED=done\ngarbage line\n' > "$D/$HOTLINE_STATUS_FILE_NAME"
[[ "$(hotline_status_class NEEDS_OVERSEER "$D/$HOTLINE_STATUS_FILE_NAME")" == blocked ]]
check "a call map declares a new word" $?
[[ "$(hotline_status_class BLOCKED "$D/$HOTLINE_STATUS_FILE_NAME")" == done ]]
check "a call map can reclass a built-in" $?
[[ "$(hotline_status_words "$D/$HOTLINE_STATUS_FILE_NAME" blocked)" == "NEEDS_OVERSEER" ]]
check "words-by-class follows the map (reclassed BLOCKED leaves blocked)" $? "got=$(hotline_status_words "$D/$HOTLINE_STATUS_FILE_NAME" blocked)"
[[ "$(hotline_status_words "" done out_of_scope)" == "DONE|WORK_COMPLETE|OUT_OF_SCOPE" ]]
check "words-by-class over several classes is one alternation" $?
[[ "$(hotline_status_class DONE "$D/missing.txt")" == done ]]
check "a missing call map falls back to the built-ins" $?
hotline_status_is_builtin AWAITING_REVIEW && ! hotline_status_is_builtin NEEDS_OVERSEER
check "built-in membership" $?

out=$(bash -c 'set -euo pipefail; source "$1"; hotline_status_words "" blocked; echo; hotline_status_class X ""' _ "$HOTLINE_DIR/scripts/status-classes.sh" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == $'BLOCKED\nunknown' ]]
check "the lookups survive a caller running set -euo pipefail with no call map" $? "rc=$rc out=[$out]"

# The dial skill names the built-ins for its reader; this keeps it in step with the map.
dial_doc=$(grep -A3 'The built-ins are' "$HOTLINE_DIR/skills/dial/SKILL.md")
missing=""; while IFS='=' read -r w _; do [[ "$dial_doc" == *"\`$w\`"* ]] || missing+=" $w"; done < <(hotline_status_builtins)
[[ -n "$dial_doc" && -z "$missing" ]]
check "the dial skill names every built-in status" $? "missing:$missing"

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf '  - %s\n' "${FAILED_CASES[@]}"; exit 1; fi
exit 0
