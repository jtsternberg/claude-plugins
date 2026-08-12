#!/usr/bin/env bash
# =============================================================================
# Register Call: Record a call in the sessions registry from call_dir metadata,
# and log it to the receiver's dial history.
#
# Reads session_id.txt plus the meta files written by persist-call-meta.sh
# (cwd.txt, mode.txt, caller_cwd.txt, caller_session.txt) and runs
# session-cache.sh set. Called by wait-for-session.sh the moment the remote
# session ID is known, and by cmux-call.sh for synchronous conference calls — so
# the registry is written by scripts, not by agent discipline.
#
# Dial history is written here too, for the same reason plus one more: the
# receiving agent used to run dial-history.sh itself (per the ringing skill),
# but that script lives in the CALLER's plugin install dir, which the ringing
# skill's own workspace-isolation rule forbids the receiver from touching. A
# receiver that obeyed isolation skipped logging; one that logged broke
# isolation. The caller has every field the entry needs, so it writes it.
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

# The nonce of THIS exchange. Superseded-surface cleanup uses it as proof that a
# surface it is about to close is the one that hosted the previous exchange, and
# not a pane the user has since repurposed — so it has to be recorded from first
# contact, not just from the first follow-up.
CALL_ID_ARGS=()
if [[ -s "$CALL_DIR/call_id.txt" ]]; then
  CALL_ID_ARGS=(--call-id "$(cat "$CALL_DIR/call_id.txt")")
fi

bash "$SCRIPT_DIR/session-cache.sh" set "$TARGET" \
  --caller-session "$CALLER_SESSION" \
  --session "$SESSION_ID" \
  --mode "$MODE" ${SURFACE_ARGS[@]+"${SURFACE_ARGS[@]}"} \
  ${CALL_ID_ARGS[@]+"${CALL_ID_ARGS[@]}"} >/dev/null 2>&1 || debug "session-cache.sh set failed"

# Dial history: "who called THIS workspace", keyed by the RECEIVER's cwd.
# --session keeps its historical meaning (the CALLER's session id); the callee's
# own session goes in --receiver-session. caller_cwd.txt is optional metadata,
# so fall back rather than skip the log entirely.
DIAL_HISTORY="$SCRIPT_DIR/../../../scripts/dial-history.sh"
if [[ -f "$DIAL_HISTORY" ]]; then
  CALLER_CWD=""
  [[ -s "$CALL_DIR/caller_cwd.txt" ]] && CALLER_CWD=$(cat "$CALL_DIR/caller_cwd.txt")
  bash "$DIAL_HISTORY" append \
    --cwd "$TARGET" \
    --session "$CALLER_SESSION" \
    --caller "${CALLER_CWD:-unknown}" \
    --mode "$MODE" \
    --receiver-session "$SESSION_ID" >/dev/null 2>&1 || debug "dial-history.sh append failed"
else
  debug "dial-history.sh not found at $DIAL_HISTORY"
fi

exit 0
