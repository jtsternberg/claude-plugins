#!/usr/bin/env bash
# =============================================================================
# Find the cmux surface a hotline session is still live in.
#
# The session cache is keyed caller→workspace, so it forgets a session the moment a
# later dial into the same workspace takes the slot — yet that session's REPL is
# still sitting in its surface. Dialing it by id (--target <id> --no-fork) then
# misses the cache and `claude --resume`s a second REPL onto the same transcript.
#
# The call dirs outlive the cache slot: each records the session, the surface and
# the exchange nonce. The NEWEST call dir naming the session is the one that says
# where it lives now (a reuse call dir counts, so a follow-up that moved the session
# moves the answer). It is trusted only when the surface still carries that call's
# nonce in its scrollback — the same identity proof close-superseded-surface.sh
# demands before it will kill a pane, and for the same reason: a UUID names one
# surface for life, but not what the user has since run in it.
#
# Usage:
#   find-live-surface.sh <session-id>
#   # → {"surface_ref": "...", "call_id": "...", "call_dir": "..."}   exit 0
#   # → nothing, exit 1 (no call dir, no surface, unreadable, or nonce absent)
#
# Reach: the call dirs are swept after HOTLINE_CALL_SWEEP_DAYS (call-dir sweep), so a
# session whose last exchange is older than about that +1 day has no call dir left to
# find; it falls back to `claude --resume` in a new surface like any other miss.
#
# This proves the surface hosted the session's last exchange, not that the REPL is
# idle. Idle/dirty-box gating stays with cmux-reuse-surface.sh.
# =============================================================================
set -uo pipefail

SESSION="${1:-}"
[[ -n "$SESSION" ]] || exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

DIR=""
while IFS= read -r f; do
  [[ "$(cat "$f" 2>/dev/null)" == "$SESSION" ]] && { DIR="$(dirname "$f")"; break; }
done < <(ls -t "${HOTLINE_CALL_HOME:-/tmp}"/hotline-call-*/session_id.txt 2>/dev/null)
[[ -n "$DIR" ]] || exit 1

SURFACE=$(tr -d '[:space:]' < "$DIR/surface_ref.txt" 2>/dev/null)
CALL_ID=$(tr -d '[:space:]' < "$DIR/call_id.txt" 2>/dev/null)
[[ "$SURFACE" =~ $UUID_RE && -n "$CALL_ID" ]] || exit 1

HIST=$(cmux_read_live "live-surface lookup of $SURFACE" --surface "$SURFACE" 2000) || exit 1
printf '%s' "$HIST" | grep -qF "$CALL_ID" || exit 1

jq -nc --arg s "$SURFACE" --arg c "$CALL_ID" --arg d "$DIR" '{surface_ref:$s, call_id:$c, call_dir:$d}'
