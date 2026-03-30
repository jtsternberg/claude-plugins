#!/usr/bin/env bash
# =============================================================================
# CMUX Call: Open a workspace in CMUX and launch Claude
#
# Usage:
#   cmux-call.sh --cwd <path> [--resume <session-id>]
#
# Outputs: {"workspace_id": "...", "cwd": "...", "session_id": "..."}
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: cmux-call.sh --cwd <path> [--resume <session-id>]"
  echo ""
  echo "Opens a workspace in CMUX and launches Claude."
  echo "Outputs: {\"workspace_id\": \"...\", \"cwd\": \"...\", \"session_id\": \"...\"}"
  exit 0
fi

CWD=""
RESUME_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$CWD" ]]; then
  echo '{"error": "No --cwd provided"}'
  exit 1
fi

WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" 2>/dev/null)
WS_ID=$(echo "$WS_OUTPUT" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)

if [[ -z "$WS_ID" ]]; then
  echo '{"error": "Failed to create CMUX workspace"}'
  exit 1
fi

if [[ -n "$RESUME_ID" ]]; then
  cmux send --workspace "$WS_ID" "claude --resume $RESUME_ID"
else
  cmux send --workspace "$WS_ID" "claude"
fi

jq -n --arg ws "$WS_ID" --arg cwd "$CWD" --arg sid "${RESUME_ID:-new}" \
  '{workspace_id: $ws, cwd: $cwd, session_id: $sid, message: "CMUX workspace opened with Claude session"}'
