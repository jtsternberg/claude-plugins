#!/usr/bin/env bash
# =============================================================================
# Regression tests for session-cache.sh — the caller-side registry of outgoing
# connections. Three behaviors are pinned here:
#
#   1. surface_ref's THREE distinct states. `--surface <ref>` points at a
#      surface, an omitted/empty --surface leaves whatever is there untouched,
#      and --clear-surface removes it. Collapsing the last two is what left a
#      dead surface_ref in the cache after a follow-up fell back to headless, so
#      the NEXT follow-up typed into a surface the session had left
#      (claude-plugins-2caw).
#
#   2. last_call_id round-trips. Superseded-surface cleanup closes a pane only
#      if that pane's scrollback still carries the nonce of the exchange it
#      hosted, so the nonce has to survive in the cache between dials.
#
#   3. --clear-surface and --surface together are REFUSED rather than resolved
#      by jq-clause ordering.
#
# $HOME is redirected per case, so nothing here touches the real
# ~/.agents-hotline. No external binaries are involved at all.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()

HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$HOTLINE_DIR/skills/dial/scripts/session-cache.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  return 0
}
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

T=$(mktemp -d /tmp/hotline-session-cache-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/target"
TARGET="$T/target"
TARGET_REAL=$(cd "$TARGET" && pwd -P)
CACHE_FILE="$T/home/.agents-hotline/sessions/caller-1.json"

conn() { jq -r --arg t "$TARGET_REAL" ".connections[\$t].$1 // \"<absent>\"" "$CACHE_FILE" 2>/dev/null; }

echo "session-cache.sh regression:"

# --- set records surface_ref and last_call_id --------------------------------
HOME="$T/home" bash "$CACHE" set "$TARGET" --caller-session caller-1 \
  --session sess-aaa --mode work_order --surface SURF-A --call-id nonce-1 >/dev/null

[[ "$(conn surface_ref)" == "SURF-A" && "$(conn last_call_id)" == "nonce-1" ]]
check "set records surface_ref and last_call_id" $? "$(cat "$CACHE_FILE" 2>/dev/null)"

# --- update with no --surface leaves it untouched ----------------------------
HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 >/dev/null
[[ "$(conn surface_ref)" == "SURF-A" && "$(conn exchange_count)" == "2" ]]
check "update without --surface leaves surface_ref untouched and bumps the count" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

# --- update --surface refreshes it ------------------------------------------
HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 \
  --surface SURF-B --call-id nonce-2 >/dev/null
[[ "$(conn surface_ref)" == "SURF-B" && "$(conn last_call_id)" == "nonce-2" ]]
check "update --surface refreshes surface_ref, --call-id refreshes the nonce" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

# --- update --clear-surface REMOVES the key ---------------------------------
# The key must be gone, not empty: `get`'s consumers test `.surface_ref //
# empty`, and dial.sh's reuse guard branches on whether it is non-empty.
HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 \
  --clear-surface >/dev/null
[[ "$(conn surface_ref)" == "<absent>" ]]
check "update --clear-surface removes surface_ref entirely" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

[[ "$(jq -r --arg t "$TARGET_REAL" '.connections[$t] | has("surface_ref")' "$CACHE_FILE")" == "false" ]]
check "the cleared key is absent rather than set to an empty string" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

# A cleared surface must not resurrect the old value on the next plain update.
HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 >/dev/null
[[ "$(conn surface_ref)" == "<absent>" && "$(conn last_call_id)" == "nonce-2" ]]
check "a cleared surface_ref stays cleared, and the nonce survives" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

# --- update --session re-keys the callee session ----------------------------
# A follow-up normally continues the cached session, so an omitted --session must
# leave it alone. It is needed when the follow-up ends up on a DIFFERENT session:
# a herdr follow-up whose agent has died falls back to a fresh launch, and herdr
# cannot re-host an existing claude session, so the new callee has a new id.
# Leaving the old one there points the next follow-up at a session nothing is
# listening on, and every answer is read from a transcript that stopped growing.
HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 \
  --surface AGENT-HOTLINE-1 >/dev/null
[[ "$(conn session_id)" == "sess-aaa" ]]
check "update without --session leaves session_id untouched" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 \
  --session sess-ccc --surface AGENT-HOTLINE-2 --call-id nonce-4 >/dev/null
[[ "$(conn session_id)" == "sess-ccc" && "$(conn surface_ref)" == "AGENT-HOTLINE-2" \
   && "$(conn last_call_id)" == "nonce-4" ]]
check "update --session re-keys session_id alongside the host handle and the nonce" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

# Restore what the cases below expect: no surface, and the original session id.
HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 \
  --session sess-aaa --clear-surface --call-id nonce-2 >/dev/null

# --- get reflects the clear -------------------------------------------------
got=$(HOME="$T/home" bash "$CACHE" get "$TARGET" --caller-session caller-1 2>/dev/null)
[[ -n "$got" && -z "$(jq -r '.surface_ref // empty' <<<"$got")" \
   && "$(jq -r '.session_id' <<<"$got")" == "sess-aaa" ]]
check "get still returns the connection, with no surface_ref" $? "got=$got"

# --- contradictory flags are refused ----------------------------------------
err=$(HOME="$T/home" bash "$CACHE" update "$TARGET" --caller-session caller-1 \
        --clear-surface --surface SURF-C 2>&1 >/dev/null)
rc=$?
[[ "$rc" -ne 0 ]] && grep -qi 'mutually exclusive' <<<"$err"
check "--clear-surface with --surface is refused, not silently resolved" $? \
  "rc=$rc err=$err"

[[ "$(conn surface_ref)" == "<absent>" ]]
check "the refused call changed nothing" $? "$(cat "$CACHE_FILE" 2>/dev/null)"

# --- set on a fresh cache file (the no-existing-file branch) -----------------
mkdir -p "$T/home2"
HOME="$T/home2" bash "$CACHE" set "$TARGET" --caller-session caller-2 \
  --session sess-bbb --mode quick_call --call-id nonce-3 >/dev/null
CACHE_FILE="$T/home2/.agents-hotline/sessions/caller-2.json"
[[ "$(conn last_call_id)" == "nonce-3" && "$(conn surface_ref)" == "<absent>" ]]
check "set on a new cache file records the nonce and omits an empty surface" $? \
  "$(cat "$CACHE_FILE" 2>/dev/null)"

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
