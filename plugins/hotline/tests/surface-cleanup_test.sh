#!/usr/bin/env bash
# =============================================================================
# Regression tests for close-superseded-surface.sh.
#
# Closing a surface KILLS its foreground process — verified live, a `sleep 400`
# in the closed surface was reaped — so this script's job is mostly to REFUSE.
# What is pinned here:
#
#   1. It closes only when every condition holds: a UUID handle, readable,
#      scrollback carries the prior exchange's nonce, REPL idle across two reads,
#      not interrupted, and no unsent text parked in the input box.
#   2. Every refusal is {"closed":false,"reason":...} and exit 0. Cleanup failing
#      must never fail the dial that triggered it.
#   3. The close call carries BOTH --workspace and --surface, and targets a
#      handle — never a tty, which cmux recycles.
#   4. cmux's own "Cannot close the last surface" refusal is recorded as a skip,
#      not raised as an error.
#   5. HOTLINE_CLOSE_SUPERSEDED=0 disables it.
#   6. A box holding Claude Code's PLACEHOLDER is not parked text, so it does not
#      spare the surface — but every ambiguity about that still does. This is the
#      DESTRUCTIVE side of the ff6g judgement, so the fail-closed cases below are
#      the load-bearing ones (claude-plugins-8vuf).
#
# TWO STUB LAYERS, because the placeholder judgement reads a styled render grid over
# a socket, which no PATH stub can intercept:
#   • `cmux` is stubbed on PATH (read-screen serves the fixture screens, tree answers
#     the workspace lookup, capabilities advertises terminal.render_grid.v1 only when
#     a case asks for it).
#   • $CMUX_SOCKET_PATH points at tests/lib/socket-stub.py answering `terminal.replay`
#     from the shared grid fixtures. The default server is POISONED, so a case that
#     makes an RPC it did not stage fails loudly.
# Nothing here touches a real cmux, opens a surface, or closes one. Poison stubs at
# the front of PATH make a missing stub fail loudly instead of escaping into the
# user's session.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$(cd "$TESTS_DIR/.." && pwd)/skills/dial/scripts/close-superseded-surface.sh"

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
# Shared with cmux-reuse-surface_test.sh and dial_wrapper_test.sh via
# tests/lib/socket-stub-harness.sh: the grid fixtures the placeholder judgement reads
# are defined once there, so no suite can test against a cmux that answers
# differently from the one another suite imagines.
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
trap 'socket_stub_cleanup; rm -rf "$POISON_BIN" "$STUBROOT"' EXIT

# The socket every case inherits is the poisoned one: an RPC nobody staged is a
# violation, not a quiet pass.
POISON_SOCK="$(socket_stub_start "$STUBROOT/poison-socket")"
: > "$STUBROOT/poison-socket/requests.log"

socket_stub_write_responses "$STUBROOT/responses"
# What the box's text looks like in ATTRIBUTES — the only place a placeholder and
# real unsent input differ (claude-plugins-ff6g).
GHOST_RESPONSES="$STUBROOT/responses/replay-ghost.json"
GHOST_FOCUSED_RESPONSES="$STUBROOT/responses/replay-ghost-focused.json"
REAL_INPUT_RESPONSES="$STUBROOT/responses/replay-real.json"
REPLAY_ERROR_RESPONSES="$STUBROOT/responses/replay-error.json"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}

GLYPH=$'\xe2\x9d\xaf'
NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"
SURF="aaaa0000-1111-4111-8111-111111111111"   # UUID-shaped: closing refuses positional refs
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
screen_idle_parked() {
  printf '%s Baked for 12s\n\n%s\n%s%shalf-typed human thought\n%s\n' \
    "✻" "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
screen_interrupted() {
  printf '  Interrupted · What should Claude do instead?\n\n%s\n%s%s\n%s\n' \
    "$RULE" "$GLYPH" "$NBSP" "$RULE"
}
# NO REPL LEFT: the callee ran /exit or claude crashed, and the surface is now a
# SHELL. Closing it kills that shell — possibly one the human is using — and every
# other gate here agrees it is safe: the nonce is still in the scrollback from when
# this pane was ours, there is no spinner, and a shell prompt reads as an empty box.
# `❯` + ordinary space is the starship/pure/oh-my-zsh shape; claude pads with U+00A0.
screen_shell_prompt() {
  printf '~/Code/target on  main\n%s%s\n' "$GLYPH" " "
}
# The themed variant, which also used to be misreported: input_box_content's
# bare-glyph fallback returned the prompt's own text as "parked input", so the
# surface was skipped forever with a reason that pointed at a human's half-typed
# thought that does not exist.
screen_shell_prompt_themed() {
  printf '%s%s~/Code/target  main !2 ?1\n' "$GLYPH" " "
}

# run_case <name> [--no-nonce] [--moving] [--busy] [--interrupted]
#          [--no-tree] [--orphan-tree] [--close-fails <msg>] [--unreadable]
#          -- [args to the script]
#
# Two knobs come from the environment of the call, matching the vocabulary
# cmux-reuse-surface_test.sh already uses for the same two things:
#   CASE_RESPONSES    canned socket responses (default: the poisoned server)
#   CASE_RENDER_GRID  non-empty → `cmux capabilities` advertises
#                     terminal.render_grid.v1, so the placeholder judgement may run
CASEDIR=""; OUT=""; CALLLOG=""; REQLOG=""
run_case() {
  local name="$1"; shift
  local no_nonce="" moving="" screen="screen_idle" no_tree="" orphan="" close_fail="" unreadable=""
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      --no-nonce)    no_nonce=1; shift ;;
      --moving)      moving=1; shift ;;
      --busy)        screen="screen_busy"; shift ;;
      --interrupted) screen="screen_interrupted"; shift ;;
      --parked)      screen="screen_idle_parked"; shift ;;
      --shell)       screen="screen_shell_prompt"; shift ;;
      --shell-themed) screen="screen_shell_prompt_themed"; shift ;;
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

  # A per-case socket server when responses are staged, else the poisoned one. The
  # poisoned log is shared across cases, so record where this case's lines start.
  local sock="$POISON_SOCK"
  if [[ -n "${CASE_RESPONSES:-}" ]]; then
    sock="$(socket_stub_start "$CASEDIR/socket" "$CASE_RESPONSES")"
    REQLOG="$CASEDIR/socket/requests.log"
  else
    REQLOG="$STUBROOT/poison-socket/requests.log"
  fi
  local reqbase=0
  [[ -f "$REQLOG" ]] && reqbase=$(wc -l < "$REQLOG" | tr -d ' ')
  echo "$reqbase" > "$CASEDIR/reqbase"

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
  capabilities)
    # Absent by default: a cmux that cannot render a styled grid leaves the
    # placeholder judgement unable to answer, which is the fail-closed direction —
    # and on THIS path fail-closed means the surface is spared.
    [[ -n "${STUB_RENDER_GRID:-}" ]] \
      && printf '{"capabilities": ["terminal.bytes.v1", "terminal.render_grid.v1"]}\n'
    exit 0 ;;
  tree)
    # --id-format both: each surface reports its stable `id` alongside its
    # positional `ref`, which is what the shared resolver in repl-state.sh reads
    # so one lookup serves a UUID handle and a legacy surface:N handle alike.
    [[ -s "$D/no_tree" ]] && exit 1
    if [[ -s "$D/orphan" ]]; then
      jq -nc '{windows:[{workspaces:[{id:"OTHER-WS",ref:"workspace:9",
        panes:[{surfaces:[{id:"SOMEONE-ELSE",ref:"surface:9"}]}]}]}]}'
    else
      jq -nc --arg s "$SURF" --arg w "$WS" \
        '{windows:[{workspaces:[{id:$w,ref:"workspace:1",panes:[{surfaces:[
           {id:$s,ref:"surface:1"},
           {id:"bbbb0000-2222-4222-8222-222222222222",ref:"surface:2"}]}]}]}]}'
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
    STUB_RENDER_GRID="${CASE_RENDER_GRID:-}" CMUX_SOCKET_PATH="$sock" \
    bash "$SCRIPT_UNDER_TEST" --settle 0 "$@" 2>&1)"
  return 0
}

closed() { [[ "$(jq -r '.closed' <<<"$OUT" 2>/dev/null)" == "true" ]]; }
reason() { jq -r '.reason // ""' <<<"$OUT" 2>/dev/null; }
close_calls() { grep -c '^close-surface' "$CALLLOG" || true; }
tree_calls() { grep -c '^tree' "$CALLLOG" || true; }
# Request lines this case produced (the poisoned log is shared, so slice it).
requests() {
  local base; base=$(cat "$CASEDIR/reqbase" 2>/dev/null || echo 0)
  [[ -f "$REQLOG" ]] || return 0
  tail -n "+$((base + 1))" "$REQLOG"
}
method_count() { requests | grep -cF "\"method\":\"$1\"" || true; }

echo "close-superseded-surface:"

# --- A surface with no REPL left in it is NEVER closed ----------------------
# The severe one. Reuse refuses an exited-REPL surface and opens a fresh one, which
# means the closer then runs on exactly that pane — and closing it kills the shell
# now living there, which the human may be using. Every other gate says yes: the
# nonce is still in the scrollback from when the pane was ours, there is no spinner,
# and a shell prompt reads as an empty box.
run_case shell_prompt --shell -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"no-repl-box"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a surface showing a shell prompt is refused with no-repl-box, and NOT closed" \
  || fail "a surface showing a shell prompt is refused with no-repl-box, and NOT closed" \
          "out=$OUT closes=$(close_calls)"

# The themed variant. Before the box gate ran first, input_box_content's bare-glyph
# fallback returned the prompt's own segments and this was reported as parked-input —
# a permanent skip with a reason describing a human thought that does not exist.
run_case shell_prompt_themed --shell-themed -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"no-repl-box"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a themed shell prompt is refused as no-repl-box, not as parked-input" \
  || fail "a themed shell prompt is refused as no-repl-box, not as parked-input" \
          "out=$OUT closes=$(close_calls)"
[[ "$(reason)" != *"parked-input"* ]] \
  && pass "…so the reason does not blame a half-typed human thought" \
  || fail "…so the reason does not blame a half-typed human thought" "out=$OUT"

# --- The happy path ---------------------------------------------------------
run_case happy -- --surface "$SURF" --expect-call-id "$NONCE"
closed && pass "an idle surface carrying the prior nonce IS closed" \
       || fail "an idle surface carrying the prior nonce IS closed" "out=$OUT"

grep -q "^close-surface --workspace $WS --surface $SURF" "$CALLLOG" \
  && pass "the close call carries BOTH --workspace and --surface" \
  || fail "the close call carries BOTH --workspace and --surface" "$(cat "$CALLLOG")"

# The workspace is resolved from the tree, not stored — so a cache written before
# workspaces were recorded still gets cleaned up.
grep -q '^tree --all --json --id-format both' "$CALLLOG" \
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

# --- Parked input is a human's half-typed thought ---------------------------
# Reuse refuses to type on top of it; closing would delete it outright.
run_case parked --parked -- --surface "$SURF" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"parked-input"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "an idle REPL with unsent text in its box is NOT closed" \
  || fail "an idle REPL with unsent text in its box is NOT closed" "out=$OUT"

echo ""
echo "  -- but a PLACEHOLDER is not unsent text (8vuf) --"

# `cmux read-screen` is plain text, where claude's ghost suggested prompt, its
# queued-messages hint and `Message @agent…` are byte-identical to typed input — so
# every one of them read as parked text and the superseded surface was never closed,
# accumulating a dead pane per turn. The discriminator is the attribute the text read
# discards: claude renders a placeholder DIM, and `terminal.replay` carries it as
# faint:true per span. The screen fixture is the SAME `--parked` one throughout this
# block; only the grid differs, which is the whole point.
#
# The asymmetry matters more here than at the reuse gate: this path DESTROYS the
# surface, so every unproven case below must still spare it.
if [[ -z "$REAL_PYTHON3" ]]; then
  echo "  ⚠ SKIP — python3 not available, so the render-grid RPC cannot be exercised"
else

# --- A ghost in the box: the surface IS closed. ------------------------------
CASE_RESPONSES="$GHOST_RESPONSES" CASE_RENDER_GRID=1 \
  run_case ghost_box --parked -- --surface "$SURF" --expect-call-id "$NONCE"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
closed && [[ "$(close_calls)" -eq 1 ]] \
  && pass "a box whose text renders DIM does not spare the surface — it IS closed" \
  || fail "a box whose text renders DIM does not spare the surface — it IS closed" \
          "out=$OUT closes=$(close_calls)"
[[ "$(method_count terminal.replay)" -ge 1 ]] \
  && pass "…having asked terminal.replay, not guessed from the text" \
  || fail "…having asked terminal.replay, not guessed from the text" "$(requests)"
# The RPC addresses a surface by workspace + surface UUID, and so does the close —
# one tree walk serves both. Two would mean the resolution grew a second copy.
[[ "$(tree_calls)" -eq 1 ]] \
  && pass "…and the workspace is resolved from the tree ONCE for both the RPC and the close" \
  || fail "…and the workspace is resolved from the tree ONCE for both the RPC and the close" \
          "$(cat "$CALLLOG")"

# The focused render of the same ghost: the placeholder's first character comes back
# as the inverse cursor cell and NOT faint. Rejecting the row on it would leave the
# fix working only on unfocused surfaces.
CASE_RESPONSES="$GHOST_FOCUSED_RESPONSES" CASE_RENDER_GRID=1 \
  run_case ghost_focused --parked -- --surface "$SURF" --expect-call-id "$NONCE"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
closed \
  && pass "one inverse cursor cell over a dim placeholder is still a placeholder" \
  || fail "one inverse cursor cell over a dim placeholder is still a placeholder" "out=$OUT"

# --- REAL unsent text: the skip is unchanged. -------------------------------
# The direction that must never regress. A false positive here deletes a human's
# half-typed thought along with the pane it was sitting in.
CASE_RESPONSES="$REAL_INPUT_RESPONSES" CASE_RENDER_GRID=1 \
  run_case real_input --parked -- --surface "$SURF" --expect-call-id "$NONCE"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
! closed && [[ "$(reason)" == *"parked-input"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a box whose text renders at NORMAL intensity is still a parked-input skip" \
  || fail "a box whose text renders at NORMAL intensity is still a parked-input skip" \
          "out=$OUT closes=$(close_calls)"

# --- FAIL CLOSED, both ways. ------------------------------------------------
# An RPC the socket refuses proves nothing, so the box stays real text and the
# surface is spared — exactly the behavior this check had before the grid existed.
CASE_RESPONSES="$REPLAY_ERROR_RESPONSES" CASE_RENDER_GRID=1 \
  run_case replay_refused --parked -- --surface "$SURF" --expect-call-id "$NONCE"
CASE_RESPONSES=""; CASE_RENDER_GRID=""
! closed && [[ "$(reason)" == *"parked-input"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a refused terminal.replay leaves the parked-input skip in place" \
  || fail "a refused terminal.replay leaves the parked-input skip in place" \
          "out=$OUT closes=$(close_calls)"
[[ "$(method_count terminal.replay)" -ge 1 ]] \
  && pass "…and it really was the REFUSAL, not an unasked question" \
  || fail "…and it really was the REFUSAL, not an unasked question" "$(requests)"

# A cmux without terminal.render_grid.v1 must not even ASK. The grid staged here says
# "ghost", so the capability gate is the only thing standing between it and a close.
CASE_RESPONSES="$GHOST_RESPONSES" \
  run_case no_render_grid --parked -- --surface "$SURF" --expect-call-id "$NONCE"
CASE_RESPONSES=""
! closed && [[ "$(reason)" == *"parked-input"* ]] && [[ "$(close_calls)" -eq 0 ]] \
  && pass "a cmux without terminal.render_grid.v1 keeps today's parked-input skip" \
  || fail "a cmux without terminal.render_grid.v1 keeps today's parked-input skip" \
          "out=$OUT closes=$(close_calls)"
[[ "$(method_count terminal.replay)" -eq 0 ]] \
  && pass "…and is never asked for a grid it cannot render" \
  || fail "…and is never asked for a grid it cannot render" "$(requests)"

fi

# --- Positional refs can name the replacement, not the superseded surface ----
# The replacement resumed the SAME session, so its scrollback replays the SAME
# nonce — a repositioned surface:N could pass the identity check while pointing
# at the pane we just delivered into.
run_case positional -- --surface "surface:211" --expect-call-id "$NONCE"
! closed && [[ "$(reason)" == *"positional-ref-unsafe"* ]] \
  && pass "a positional surface:N ref is never closed" \
  || fail "a positional surface:N ref is never closed" "out=$OUT"

[[ "$(close_calls)" -eq 0 ]] \
  && pass "…and it reads no screens and closes nothing" \
  || fail "…and it reads no screens and closes nothing" "$(cat "$CALLLOG")"

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
