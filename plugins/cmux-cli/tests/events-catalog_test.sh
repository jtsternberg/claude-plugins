#!/usr/bin/env bash
# =============================================================================
# Regression guard: the `cmux events` documentation stays true.
#
# The skill now routes waiting and send-verification through `cmux events`
# instead of read-screen forensics, which makes three things load-bearing:
#
#   1. events.md documents the event names the SKILL.md recipes actually name.
#      A doc edit that drops workspace.prompt.submitted or agent.hook.Stop
#      silently strands the recipe that depends on it.
#   2. events.md's invocation contract matches the installed CLI's flags.
#      The recipes pass --no-ack/--no-heartbeat/--timeout/--after for stated
#      reasons; if any of those stop existing, the recipes are wrong.
#   3. Every event name cmux actually emits is one we document. This direction
#      is deliberate: a live replay on a quiet machine will not contain every
#      name, so "documented ⊆ observed" would fail spuriously. "observed ⊆
#      documented" instead catches cmux ADDING a name we haven't written up.
#
# Parts 2 and 3 need real cmux and self-skip without it. Part 1 is pure text
# and runs everywhere, CI included.
# =============================================================================
set -u

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/using-cmux-cli"
SKILL_MD="$SKILL_DIR/SKILL.md"
EVENTS_MD="$SKILL_DIR/references/events.md"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

echo "events-catalog: documentation guard"

# --- Part 1: doc self-consistency (runs everywhere) -------------------------

[[ -f "$EVENTS_MD" ]] \
  && pass "references/events.md exists" \
  || fail "references/events.md exists" "missing: $EVENTS_MD"

grep -qF 'references/events.md' "$SKILL_MD" \
  && pass "SKILL.md links references/events.md" \
  || fail "SKILL.md links references/events.md" "no link found in SKILL.md"

# The names the SKILL.md recipes name must be documented in the reference.
for name in workspace.prompt.submitted agent.hook.Stop surface.created; do
  grep -qF "$name" "$EVENTS_MD" \
    && pass "events.md documents $name" \
    || fail "events.md documents $name" "not found in events.md"
done

# The two measurement fields are what make send-verification a measurement
# rather than a warning. Losing either collapses the recipe back to guesswork.
for field in message_length message_preview; do
  grep -qF "$field" "$EVENTS_MD" \
    && pass "events.md documents payload.$field" \
    || fail "events.md documents payload.$field" "not found in events.md"
done

# The double-fire trap: agent.hook.* arrives twice, phase received/completed.
grep -qF 'phase' "$EVENTS_MD" && grep -qF 'completed' "$EVENTS_MD" \
  && pass "events.md documents the agent.hook.* phase double-fire" \
  || fail "events.md documents the agent.hook.* phase double-fire" \
          "expected the received/completed phase trap to be described"

if ! command -v cmux >/dev/null 2>&1; then
  echo "events-catalog: cmux not installed — skipping live probes (parts 2 and 3)"
  echo "$PASS passed, $FAIL failed (live probes skipped: cmux missing)"
  [[ $FAIL -eq 0 ]] || { printf 'failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
  exit 0
fi

if ! cmux ping >/dev/null 2>&1; then
  echo "events-catalog: cmux installed but not reachable — skipping live probes"
  echo "$PASS passed, $FAIL failed (live probes skipped: cmux unreachable)"
  [[ $FAIL -eq 0 ]] || { printf 'failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
  exit 0
fi

# --- Part 2: the documented flags exist ------------------------------------

HELP="$(cmux events --help 2>&1 || true)"
for flag in --after --cursor-file --name --category --limit --timeout --snapshot --no-ack --no-heartbeat; do
  grep -qF -- "$flag" <<<"$HELP" \
    && pass "cmux events supports $flag" \
    || fail "cmux events supports $flag" "absent from cmux events --help"
done

# --- Part 3: no undocumented event names in a live replay -------------------

if ! command -v jq >/dev/null 2>&1; then
  echo "events-catalog: jq missing — skipping the live catalog comparison"
  echo "$PASS passed, $FAIL failed (catalog comparison skipped: jq missing)"
  [[ $FAIL -eq 0 ]] || { printf 'failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
  exit 0
fi

# TWO SAMPLES, AND ONLY THEIR INTERSECTION CAN FAIL THE SUITE.
#
# This part reads the REAL cmux stream, which is the only thing that can catch a
# name cmux has started emitting that events.md does not document — the whole
# reason it is not a static doc check. The cost is that its input is live state:
# it failed inside a full `run-all` while a second `run-all` was running and
# passed alone moments later, so as a single sample it reports the machine's
# recent history as if it were a property of this change-set.
#
# The fix is reproducibility, not a wider window. A name present in TWO
# independent replays taken seconds apart is a real gap in the doc and fails; a
# name present in only one is reported and does not, because that is the shape of
# buffer contention, a rolling window dropping frames under load, and the
# retained replay's own habit of not reaching the newest frames. Widening the
# window would have made a flake rarer without making it wrong less often, and
# serializing the suite would have fixed nothing about a name that is simply new.
#
# Each replay is bounded: --timeout exits 1 once the retained buffer is drained,
# which is the normal end of one here rather than a failure, and stderr stays out
# of the file so jq never sees the timeout line.
sample_names() {  # → one event name per line, deduped
  local f
  f="$(mktemp)"
  cmux events --after 0 --no-ack --no-heartbeat --limit 900 --timeout 8 \
    >"$f" 2>/dev/null || true
  jq -r 'select(.type=="event") | .name' "$f" 2>/dev/null | sort -u
  rm -f "$f"
}

OBSERVED_A="$(sample_names)"
OBSERVED_B="$(sample_names)"

# Names in BOTH samples. comm needs sorted input, which sort -u already gives.
OBSERVED="$(comm -12 <(printf '%s\n' "$OBSERVED_A") <(printf '%s\n' "$OBSERVED_B"))"
# Names in exactly one — advisory only.
ONE_SAMPLE_ONLY="$(comm -3 <(printf '%s\n' "$OBSERVED_A") <(printf '%s\n' "$OBSERVED_B") | tr -d '\t' | sed '/^$/d')"

if [[ -z "$OBSERVED_A$OBSERVED_B" ]]; then
  echo "events-catalog: replay returned no events — skipping the catalog comparison"
else
  undocumented_in() {  # <newline list> → the ones events.md does not mention
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      grep -qF "$name" "$EVENTS_MD" || printf '%s\n' "$name"
    done <<<"$1"
  }

  UNDOCUMENTED=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && UNDOCUMENTED+=("$name")
  done <<<"$(undocumented_in "$OBSERVED")"

  if [[ ${#UNDOCUMENTED[@]} -eq 0 ]]; then
    pass "every event name seen in BOTH replays is documented ($(printf '%s\n' "$OBSERVED" | sed '/^$/d' | wc -l | tr -d ' ') names in both)"
  else
    fail "every event name seen in BOTH replays is documented" \
         "undocumented: ${UNDOCUMENTED[*]} — present in two independent replays, so this is a real doc gap, not sampling noise. Add them to references/events.md"
  fi

  # ADVISORY, deliberately not a failure: one sample is not evidence. Printed
  # rather than swallowed, because the next reader of this output is the person
  # deciding whether the doc is complete.
  if [[ -n "$ONE_SAMPLE_ONLY" ]]; then
    FLAKY_UNDOC="$(undocumented_in "$ONE_SAMPLE_ONLY")"
    if [[ -n "$FLAKY_UNDOC" ]]; then
      echo "  ℹ seen in only ONE of two replays and undocumented: $(printf '%s ' $FLAKY_UNDOC)"
      echo "    Not failing on it — a single sample is indistinguishable from buffer"
      echo "    contention. Re-run this suite; if it persists in both samples it fails."
    fi
  fi
fi

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || { printf 'failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
exit 0
