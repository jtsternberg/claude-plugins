#!/usr/bin/env bash
# =============================================================================
# The [FOLLOW_UP] invocation: how an interactive follow-up reaches a live callee
# (claude-plugins-2i6g).
#
# A follow-up pasted RAW into a claude REPL arrives as a <pasted_content> block,
# and the harness tells the callee to take instructions from pasted text only
# where the user's own message asks — so callees refused the work they were sent.
# Interactive follow-ups therefore re-invoke `/hotline:hotline-ringing [FOLLOW_UP]
# …` and ride the same split delivery as first contact, which puts the message in
# command-args.
#
# Two things this suite pins:
#   • the follow-up invocation is a slash command to every helper that decides
#     nonce placement and split delivery — it must get both, or it regresses to
#     the raw shape;
#   • it carries [MODE:]/[CALLER:]/[SESSION:] tags, and a follow-up is NOT a new
#     call to register. The launchers parse those tags to register first contact;
#     one that registered a follow-up would reset the cached connection's
#     exchange_count and `started`, and log a second dial-history entry.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/repl-state.sh
source "$HOTLINE_DIR/scripts/repl-state.sh"
PERSIST="$HOTLINE_DIR/skills/dial/scripts/persist-call-meta.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/followup-invocation-XXXXX")
trap 'rm -rf "$T"' EXIT

FOLLOW='/hotline:hotline-ringing [FOLLOW_UP] [MODE: work_order] [CALLER: /c/cwd] [SESSION: caller-9]
and now step 2
more of it'
FIRST='/hotline:hotline-ringing [MODE: work_order] [CALLER: /c/cwd] [SESSION: caller-9]
run the suite'

echo "follow-up invocation:"
echo ""
echo "  -- recognition --"

hotline_is_followup_invocation "$FOLLOW"
check "a [FOLLOW_UP] ringing invocation is a follow-up" $?
hotline_is_followup_invocation "$(hotline_inject_call_id N "$FOLLOW")"
check "…and still is once the nonce is spliced in ahead of the tag" $?
! hotline_is_followup_invocation "$FIRST"
check "a first-contact invocation is not" $?
! hotline_is_followup_invocation $'a raw message\nthat mentions [FOLLOW_UP] on line 2'
check "a raw message that merely mentions the tag is not" $?
! hotline_is_followup_invocation $'please add [FOLLOW_UP] handling\nto the parser'
check "nor is one mentioning it on line 1 without the ringing command" $?

echo ""
echo "  -- delivery shape --"

INJECTED=$(hotline_inject_call_id N "$FOLLOW")
[[ "$(sed -n 1p <<<"$INJECTED")" == '/hotline:hotline-ringing [CALL_ID: N] [FOLLOW_UP] [MODE: work_order] [CALLER: /c/cwd] [SESSION: caller-9]' ]]
check "the nonce goes INLINE after the command token, as for first contact" $? \
  "line1=$(sed -n 1p <<<"$INJECTED")"
printf '%s' "$INJECTED" > "$T/payload.md"
hotline_payload_needs_split_delivery "$T/payload.md"
check "a follow-up with a message takes the split delivery" $?

echo ""
echo "  -- registration --"

mkdir -p "$T/first" "$T/follow"
printf '%s' "$FIRST"  > "$T/first.md"
printf '%s' "$INJECTED" > "$T/follow.md"
bash "$PERSIST" "$T/first"  /callee/cwd --prompt-file "$T/first.md"
bash "$PERSIST" "$T/follow" /callee/cwd --prompt-file "$T/follow.md"

[[ "$(cat "$T/first/mode.txt" 2>/dev/null)" == "work_order" \
   && "$(cat "$T/first/caller_session.txt" 2>/dev/null)" == "caller-9" ]]
check "first contact's tags are persisted for registration" $? \
  "files: $(ls "$T/first" | tr '\n' ' ')"
[[ ! -e "$T/follow/mode.txt" && ! -e "$T/follow/caller_cwd.txt" && ! -e "$T/follow/caller_session.txt" ]]
check "a follow-up's tags are NOT persisted, so register-call.sh records nothing" $? \
  "files: $(ls "$T/follow" | tr '\n' ' ')"
[[ "$(cat "$T/follow/cwd.txt" 2>/dev/null)" == "/callee/cwd" ]]
check "…while the callee cwd still is (the transcript path is derived from it)" $? \
  "files: $(ls "$T/follow" | tr '\n' ' ')"

echo ""
echo "follow-up invocation: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
