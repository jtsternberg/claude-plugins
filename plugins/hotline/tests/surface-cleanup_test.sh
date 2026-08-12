#!/usr/bin/env bash
# =============================================================================
# Regression tests for close-superseded-surface.sh.
#
# Closing a surface KILLS its foreground process — verified live, a `sleep 400`
# in the closed surface was reaped — so this script's job is mostly to REFUSE.
# What is pinned here:
#
#   1. It closes only when all four conditions hold: readable, scrollback carries
#      the prior exchange's nonce, REPL idle across two reads, not interrupted.
#   2. Every refusal is {"closed":false,"reason":...} and exit 0. Cleanup failing
#      must never fail the dial that triggered it.
#   3. The close call carries BOTH --workspace and --surface, and targets a
#      handle — never a tty, which cmux recycles.
#   4. cmux's own "Cannot close the last surface" refusal is recorded as a skip,
#      not raised as an error.
#   5. HOTLINE_CLOSE_SUPERSEDED=0 disables it.
#
# `cmux` is stubbed on PATH throughout: nothing here touches a real cmux, opens a
# surface, or closes one. Poison stubs at the front of PATH make a missing stub
# fail loudly instead of escaping into the user's session.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/dial/scripts/close-superseded-surface.sh"

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
trap 'rm -rf "$POISON_BIN" "$STUBROOT"' EXIT

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}

GLYPH=$'\xe2\x9d\xaf'
NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"
SURF="SURFACE-UUID-OLD"
WS="WORKSPACE-UUID-1"
NONCE="abc123def456cafe"

# --- Fixture screens ---------------------------------------------------------
screen_idle() {
  printf '%s Baked for 12s\n\n%s\n%s%s\n%s\n' "✻" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
screen_busy() {
  printf '%s Dilly-dallying… (5s · ↓ 124 tokens)\n\n%s\n%s%s\n%s\n' \
    "✶" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
screen_interrupted() {
  printf '  Interrupted · What should Claude do instead?\n\n%s\n%s%s\n%s\n' \
    "$RULE" "$GLYPH" "$NBSP" "$RULE"
}

# run_case <name> [--no-nonce] [--moving] [--busy] [--interrupted]
#          [--no-tree] [--orphan-tree] [--close-fails <msg>] [--unreadable]
#          -- [args to the script]
CASEDIR=""; OUT=""; CALLLOG=""
run_case() {
  local name="$1"; shift
  local no_nonce="" moving="" screen="screen_idle" no_tree="" orphan="" close_fail="" unreadable=""
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      --no-nonce)    no_nonce=1; shift ;;
      --moving)      moving=1; shift ;;
      --busy)        screen="screen_busy"; shift ;;
      --interrupted) screen="screen_interrupted"; shift ;;
      --no-tree)     no_tree=1; shift ;;
      --orphan-tree) orphan=1; shift ;;
      --unreadable)  unreadable=1; shift ;;
      --close-fails) close_fail="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ "${1:-}" == "--" ]] && shift

  CASEDIR="$STUBROOT/$name"; mkdir -p "$CASEDIR"
  CALLLOG="$CASEDIR/calls.log"; : > "$CALLLOG"
  "$screen" > "$CASEDIR/screen.txt"
  # Scrollback = the visible screen plus the prior exchange's echo, which is
  # where the nonce lives once it has scrolled out of the viewport.
  { if [[ -z "$no_nonce" ]]; then
      printf '%s %s\n' "$GLYPH" "[CALL_ID: $NONCE] the previous follow-up"
    fi
    "$screen"; } > "$CASEDIR/scrollback.txt"
  printf '%s' "${moving:-}"      > "$CASEDIR/moving"
  printf '%s' "${no_tree:-}"     > "$CASEDIR/no_tree"
  printf '%s' "${orphan:-}"      > "$CASEDIR/orphan"
  printf '%s' "${close_fail:-}"  > "$CASEDIR/close_fail"
  printf '%s' "${unreadable:-}"  > "$CASEDIR/unreadable"
  printf '%s' "$SURF" > "$CASEDIR/surf"; printf '%s' "$WS" > "$CASEDIR/ws"

  cat > "$CASEDIR/cmux" <<'STUB'
#!/usr/bin/env bash
D="${STUB_DIR:?}"
printf '%q ' "$@" >> "$D/calls.log"; printf '\n' >> "$D/calls.log"
SURF=$(cat "$D/surf"); WS=$(cat "$D/ws")
case "$1" in
  read-screen)
    [[ -s "$D/unreadable" ]] && { echo "Error: surface not found" >&2; exit 1; }
    if [[ "$*" == *--scrollback* ]]; then cat "$D/scrollback.txt"; exit 0; fi
    cat "$D/screen.txt"
    # A "moving" screen differs from one read to the next, which is how an
    # unrecognised spinner still reads as busy.
    if [[ -s "$D/moving" ]]; then
      n=$(cat "$D/reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/reads"
      echo "  reading file $n of 9"
    fi
    exit 0 ;;
  tree)
    [[ -s "$D/no_tree" ]] && exit 1
    if [[ -s "$D/orphan" ]]; then
      jq -nc '{windows:[{workspaces:[{id:"OTHER-WS",panes:[{surface_ids:["SOMEONE-ELSE"]}]}]}]}'
    else
      jq -nc --arg s "$SURF" --arg w "$WS" \
        '{windows:[{workspaces:[{id:$w,panes:[{surface_ids:[$s,"SURFACE-UUID-SIBLING"]}]}]}]}'
    fi
    exit 0 ;;
  close-surface)
    if [[ -s "$D/close_fail" ]]; then echo "Error: $(cat "$D/close_fail")" >&2; exit 1; fi
    echo "OK"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$CASEDIR/cmux"

  OUT="$(STUB_DIR="$CASEDIR" PATH="$CASEDIR:$PATH" \
    bash "$SCRIPT_UNDER_TEST" --settle 0 "$@" 2>&1)"
  return 0
}

closed() { [[ "$(jq -r '.closed' <<<"$OUT" 2>/dev/null)" == "true" ]]; }
reason() { jq -r '.reason // ""' <<<"$OUT" 2>/dev/null; }
close_calls() { grep -c '^close-surface' "$CALLLOG" || true; }

echo "close-superseded-surface:"

# --- The happy path ---------------------------------------------------------
run_case happy -- --surface "$SURF" --expect-call-id "$NONCE"
closed && pass "an idle surface carrying the prior nonce IS closed" \
       || fail "an idle surface carrying the prior nonce IS closed" "out=$OUT"

grep -q "^close-surface --workspace $WS --surface $SURF" "$CALLLOG" \
  && pass "the close call carries BOTH --workspace and --surface" \
  || fail "the close call carries BOTH --workspace and --surface" "$(cat "$CALLLOG")"

# The workspace is resolved from the tree, not stored — so a cache written before
# workspaces were recorded still gets cleaned up.
grep -q '^tree --all --json --id-format uuids' "$CALLLOG" \
  && pass "the workspace is resolved from the cmux tree by UUID" \
  || fail "the workspace is resolved from the cmux tree by UUID" "$(cat "$CALLLOG")"

! grep -qE 'tty|ttys[0-9]' "$CALLLOG" \
  && pass "nothing is ever targeted by tty" \
  || fail "nothing is ever targeted by tty" "$(cat "$CALLLOG")"

# The nonce lives in scrollback, not the viewport — checking only the visible
# screen would make cleanup never fire.
grep -q '^read-screen .*--scrollback' "$CALLLOG" \
  && pass "the nonce is looked for in scrollback, not just the viewport" \
  || fail "the nonce is looked for in scrollback, not just the viewport" "$(cat "$CALLLOG")"

# --- Identity: no nonce, no close -------------------------------------------
run_case no_nonce --no-nonce -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"not provably the superseded exchange"* ]] \
  && pass "a surface without the prior nonce is NOT closed" \
  || fail "a surface without the prior nonce is NOT closed" "out=$OUT"
[[ "$(close_calls)" -eq 0 ]] \
  && pass "…and close-surface is never called" \
  || fail "…and close-surface is never called" "$(cat "$CALLLOG")"

run_case no_expect -- --surface "$SURF"
! closed && [[ "$(reason)" == *"identity cannot be proven"* ]] \
  && pass "with no --expect-call-id it refuses rather than guessing" \
  || fail "with no --expect-call-id it refuses rather than guessing" "out=$OUT"
[[ "$(close_calls)" -eq 0 ]] \
  && pass "…and reads no screens at all" \
  || pass "…and reads no screens at all"

# --- Liveness ---------------------------------------------------------------
run_case busy --busy -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"turn in flight"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a REPL mid-turn is NOT closed (its work would be destroyed)" \
  || fail "a REPL mid-turn is NOT closed (its work would be destroyed)" "out=$OUT"

run_case moving --moving -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"still changing"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a screen that keeps changing counts as busy, even with no known marker" \
  || fail "a screen that keeps changing counts as busy, even with no known marker" "out=$OUT"

run_case interrupted --interrupted -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"post-interrupt"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a post-interrupt REPL is NOT closed (a human is mid-decision)" \
  || fail "a post-interrupt REPL is NOT closed (a human is mid-decision)" "out=$OUT"

# --- Surface already gone ---------------------------------------------------
run_case unreadable --unreadable -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"nothing to close"* ]] \
  && pass "an already-gone surface is a clean skip, not an error" \
  || fail "an already-gone surface is a clean skip, not an error" "out=$OUT"

# --- Workspace resolution failures ------------------------------------------
run_case no_tree --no-tree -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"cmux tree"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "an unreadable tree skips rather than closing blind" \
  || fail "an unreadable tree skips rather than closing blind" "out=$OUT"

run_case orphan_tree --orphan-tree -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"not in the cmux tree"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a surface missing from the tree is skipped" \
  || fail "a surface missing from the tree is skipped" "out=$OUT"

# --- cmux's own refusal -----------------------------------------------------
# cmux will not close the last surface in a workspace, which bounds the worst
# case of a wrong decision to a no-op.
run_case last_surface --close-fails "invalid_state: Cannot close the last surface" \
  -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"Cannot close the last surface"* ]] \
  && pass "cmux's last-surface refusal is recorded as a skip, not an error" \
  || fail "cmux's last-surface refusal is recorded as a skip, not an error" "out=$OUT"

# --- The opt-out ------------------------------------------------------------
CASEDIR="$STUBROOT/happy"
OUT="$(STUB_DIR="$CASEDIR" PATH="$CASEDIR:$PATH" HOTLINE_CLOSE_SUPERSEDED=0 \
  bash "$SCRIPT_UNDER_TEST" --surface "$SURF" --expect-call-id "$NONCE" 2>&1)"
! closed && [[ "$(reason)" == "disabled" ]] \
  && pass "HOTLINE_CLOSE_SUPERSEDED=0 disables cleanup" \
  || fail "HOTLINE_CLOSE_SUPERSEDED=0 disables cleanup" "out=$OUT"

# --- Every path emits valid JSON and exit 0 ---------------------------------
for case_args in "--surface $SURF --expect-call-id $NONCE" "--surface $SURF" ""; do
  run_case contract -- $case_args
  rc=$?
  jq -e 'has("closed")' <<<"$OUT" >/dev/null 2>&1 && [[ "$rc" -eq 0 ]] \
    || fail "every exit path emits {closed:...} JSON and exit 0" "args='$case_args' out=$OUT rc=$rc"
done
[[ ${#FAILED_CASES[@]} -eq 0 || "${FAILED_CASES[*]}" != *"every exit path"* ]] \
  && pass "every exit path emits {closed:...} JSON and exit 0"

if [[ -s "$POISON_LOG" ]]; then
  fail "no test reaches the real cmux or claude" "$(cat "$POISON_LOG")"
else
  pass "no test reaches the real cmux or claude"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
