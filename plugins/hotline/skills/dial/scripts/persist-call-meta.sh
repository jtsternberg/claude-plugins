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
#   persist-call-meta.sh <call_dir> <receiver_cwd> --prompt-file <path>
#
# --prompt-file is preferred wherever the caller already has the prompt on disk:
# the tags this script wants are a handful of bytes, but the prompt they are
# embedded in is the whole work order, and an argv copy of it is readable by any
# local user through `ps` (claude-plugins-86ka).
#
# Never fails the caller: missing tags simply produce no files.
# =============================================================================
set -uo pipefail

CALL_DIR="${1:-}"
RECV_CWD="${2:-}"
PROMPT="${3:-}"
if [[ "${3:-}" == "--prompt-file" ]]; then
  PROMPT=""
  [[ -f "${4:-}" ]] && PROMPT=$(cat "$4")
fi

[[ -d "$CALL_DIR" ]] || exit 0

if [[ -n "$RECV_CWD" && ! -f "$CALL_DIR/cwd.txt" ]]; then
  echo "$RECV_CWD" > "$CALL_DIR/cwd.txt"
fi

# A [FOLLOW_UP] invocation carries the same tags, but it continues a call that is
# already registered; dial.sh `update`s the cache for it (repl-state.sh has why).
# shellcheck source=../../../scripts/repl-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/repl-state.sh"
hotline_is_followup_invocation "$PROMPT" && exit 0

MODE=$(sed -n 's/.*\[MODE: \([a-z_]*\)\].*/\1/p' <<<"$PROMPT" | head -1)
CALLER_CWD=$(sed -n 's/.*\[CALLER: \([^]]*\)\].*/\1/p' <<<"$PROMPT" | head -1)
CALLER_SESSION=$(sed -n 's/.*\[SESSION: \([^]]*\)\].*/\1/p' <<<"$PROMPT" | head -1)

[[ -n "$MODE" ]] && echo "$MODE" > "$CALL_DIR/mode.txt"
[[ -n "$CALLER_CWD" ]] && echo "$CALLER_CWD" > "$CALL_DIR/caller_cwd.txt"
[[ -n "$CALLER_SESSION" ]] && echo "$CALLER_SESSION" > "$CALL_DIR/caller_session.txt"

exit 0
