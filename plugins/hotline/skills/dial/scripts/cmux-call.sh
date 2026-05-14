#!/usr/bin/env bash
# =============================================================================
# CMUX Call: Open a workspace in CMUX and launch Claude
#
# Usage:
#   cmux-call.sh --cwd <path> [--prompt <text>] [--resume <session-id>]
#
# Outputs: {"workspace_id": "...", "cwd": "...", "session_id": "..."}
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: cmux-call.sh --cwd <path> [--prompt <text>] [--resume <session-id>] [--name <name>] [--fork-session] [--tools <tools>]"
  echo ""
  echo "Opens a workspace in CMUX and launches Claude."
  echo "Outputs: {\"workspace_id\": \"...\", \"cwd\": \"...\", \"session_id\": \"...\"}"
  echo ""
  echo "  --prompt <text>  Optional prompt to deliver to the interactive session"
  echo "  --tools <tools>  Override allowed tools (default: \"Bash Read Edit Write Grep Glob\")"
  exit 0
fi

CWD=""
PROMPT=""
RESUME_ID=""
SESSION_NAME=""
FORK_SESSION=false
ALLOWED_TOOLS="Bash Read Edit Write Grep Glob"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    --name) SESSION_NAME="$2"; shift 2 ;;
    --fork-session) FORK_SESSION=true; shift ;;
    --tools) ALLOWED_TOOLS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$CWD" ]]; then
  echo '{"error": "No --cwd provided"}'
  exit 1
fi

WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" 2>&1)

# cmux returns "OK workspace:<N>" — extract the ref
WS_REF=$(echo "$WS_OUTPUT" | grep -oE 'workspace:[0-9]+' | head -1 || true)

if [[ -z "$WS_REF" ]]; then
  jq -n --arg err "cmux new-workspace failed: $WS_OUTPUT" '{error: $err}'
  exit 1
fi

SESSION_ID_PRESET=""
if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID_PRESET="$RESUME_ID"
else
  SESSION_ID_PRESET=$(
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' \
    || cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || {
         b=$(od -A n -N 16 -t x1 /dev/urandom | tr -d ' \n')
         printf '%s-%s-4%s-%x%s-%s\n' \
           "${b:0:8}" "${b:8:4}" "${b:13:3}" \
           "$(( (16#${b:16:1} & 0x3) | 0x8 ))" "${b:17:3}" "${b:20:12}"
       } \
    || true
  )
fi

CMD="claude"
if [[ -n "$RESUME_ID" ]]; then
  printf -v quoted_resume "%q" "$RESUME_ID"
  CMD+=" --resume $quoted_resume"
elif [[ -n "$SESSION_ID_PRESET" ]]; then
  printf -v quoted_session "%q" "$SESSION_ID_PRESET"
  CMD+=" --session-id $quoted_session"
fi
if [[ -n "$SESSION_NAME" ]]; then
  printf -v quoted_name "%q" "$SESSION_NAME"
  CMD+=" -n $quoted_name"
fi
if $FORK_SESSION; then
  CMD+=" --fork-session"
fi
printf -v quoted_tools "%q" "$ALLOWED_TOOLS"
CMD+=" --allowedTools $quoted_tools"
if [[ -n "$PROMPT" ]]; then
  printf -v quoted_prompt "%q" "$PROMPT"
  CMD+=" $quoted_prompt"
fi

cmux send --workspace "$WS_REF" "$CMD\n"

jq -n --arg ws "$WS_REF" --arg cwd "$CWD" --arg sid "${SESSION_ID_PRESET:-new}" \
  '{workspace_ref: $ws, cwd: $cwd, session_id: $sid, message: "CMUX workspace opened with Claude session"}'
