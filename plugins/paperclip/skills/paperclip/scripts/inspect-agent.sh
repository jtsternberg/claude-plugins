#!/usr/bin/env bash
# inspect-agent.sh — dump all four instruction files for a Paperclip agent
set -euo pipefail

COMPANY_ID="${1:-}"
AGENT_ID="${2:-}"

if [[ -z "$COMPANY_ID" || -z "$AGENT_ID" ]]; then
  echo "Usage: inspect-agent.sh <company-id> <agent-id>" >&2
  exit 1
fi

BASE="${PAPERCLIP_DATA_DIR:-$HOME/.paperclip/instances/default}/companies/$COMPANY_ID/agents/$AGENT_ID/instructions"

if [[ ! -d "$BASE" ]]; then
  echo "Error: instruction directory not found: $BASE" >&2
  exit 1
fi

for file in AGENTS.md SOUL.md HEARTBEAT.md TOOLS.md; do
  path="$BASE/$file"
  echo "=========================================="
  echo "## $file"
  echo "=========================================="
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    echo "(not present)"
  fi
  echo
done
