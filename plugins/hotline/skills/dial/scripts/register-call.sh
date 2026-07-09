#!/usr/bin/env bash
# =============================================================================
# Register Call: Record a call in the sessions registry from call_dir metadata.
#
# Reads session_id.txt plus the meta files written by persist-call-meta.sh
# (cwd.txt, mode.txt, caller_session.txt) and runs session-cache.sh set.
# Called by wait-for-session.sh the moment the remote session ID is known,
# and by cmux-call.sh for synchronous conference calls — so the registry is
# written by scripts, not by agent discipline.
#
# Usage:
#   register-call.sh <call_dir>
#
# Silent no-op (exit 0) when any required metadata is missing, so callers
# never fail on it. Set HOTLINE_DEBUG=1 to see why a registration was skipped.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALL_DIR="${1:-}"

debug() { [[ "${HOTLINE_DEBUG:-}" == "1" ]] && echo "register-call: $*" >&2; return 0; }

[[ -d "$CALL_DIR" ]] || { debug "no call_dir"; exit 0; }

for f in session_id.txt cwd.txt mode.txt caller_session.txt; do
  [[ -s "$CALL_DIR/$f" ]] || { debug "missing $f — skipping registration"; exit 0; }
done

SESSION_ID=$(cat "$CALL_DIR/session_id.txt")
TARGET=$(cat "$CALL_DIR/cwd.txt")
MODE=$(cat "$CALL_DIR/mode.txt")
CALLER_SESSION=$(cat "$CALL_DIR/caller_session.txt")

# surface_ref is optional — present only for visible surface placements
# (side-by-side / --window), absent for headless / detached calls. When present,
# record it so a follow-up can reuse the surface the session already lives in.
SURFACE_ARGS=()
if [[ -s "$CALL_DIR/surface_ref.txt" ]]; then
  SURFACE_ARGS=(--surface "$(cat "$CALL_DIR/surface_ref.txt")")
fi

bash "$SCRIPT_DIR/session-cache.sh" set "$TARGET" \
  --caller-session "$CALLER_SESSION" \
  --session "$SESSION_ID" \
  --mode "$MODE" ${SURFACE_ARGS[@]+"${SURFACE_ARGS[@]}"} >/dev/null 2>&1 || debug "session-cache.sh set failed"

exit 0
