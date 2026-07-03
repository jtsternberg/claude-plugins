#!/usr/bin/env bash
# =============================================================================
# Persist Call Meta: Write call metadata into the call_dir at launch time.
#
# Parses the ringing prompt's [MODE:], [CALLER:], and [SESSION:] tags and
# writes them (plus the receiver cwd) as files in the call_dir. This lets
# wait-for-session.sh / register-call.sh record the call in the sessions
# registry deterministically — previously registration relied on the dialing
# agent running session-cache.sh set after wait-for-response.sh, a step
# routinely skipped on visible cmux side-by-side calls.
#
# Usage:
#   persist-call-meta.sh <call_dir> <receiver_cwd> <prompt>
#
# Never fails the caller: missing tags simply produce no files.
# =============================================================================
set -uo pipefail

CALL_DIR="${1:-}"
RECV_CWD="${2:-}"
PROMPT="${3:-}"

[[ -d "$CALL_DIR" ]] || exit 0

if [[ -n "$RECV_CWD" && ! -f "$CALL_DIR/cwd.txt" ]]; then
  echo "$RECV_CWD" > "$CALL_DIR/cwd.txt"
fi

MODE=$(sed -n 's/.*\[MODE: \([a-z_]*\)\].*/\1/p' <<<"$PROMPT" | head -1)
CALLER_CWD=$(sed -n 's/.*\[CALLER: \([^]]*\)\].*/\1/p' <<<"$PROMPT" | head -1)
CALLER_SESSION=$(sed -n 's/.*\[SESSION: \([^]]*\)\].*/\1/p' <<<"$PROMPT" | head -1)

[[ -n "$MODE" ]] && echo "$MODE" > "$CALL_DIR/mode.txt"
[[ -n "$CALLER_CWD" ]] && echo "$CALLER_CWD" > "$CALL_DIR/caller_cwd.txt"
[[ -n "$CALLER_SESSION" ]] && echo "$CALLER_SESSION" > "$CALL_DIR/caller_session.txt"

exit 0
