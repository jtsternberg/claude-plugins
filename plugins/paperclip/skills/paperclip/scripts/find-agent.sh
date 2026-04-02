#!/usr/bin/env bash
# find-agent.sh — list all companies and agents from the filesystem
# Useful when you don't know the IDs yet
set -euo pipefail

DATA_DIR="${PAPERCLIP_DATA_DIR:-$HOME/.paperclip/instances/default}"
COMPANIES_DIR="$DATA_DIR/companies"

if [[ ! -d "$COMPANIES_DIR" ]]; then
  echo "Error: companies directory not found: $COMPANIES_DIR" >&2
  exit 1
fi

for company_dir in "$COMPANIES_DIR"/*/; do
  company_id=$(basename "$company_dir")
  echo "Company: $company_id"
  agents_dir="$company_dir/agents"
  if [[ -d "$agents_dir" ]]; then
    for agent_dir in "$agents_dir"/*/; do
      [[ -d "$agent_dir" ]] || continue
      agent_id=$(basename "$agent_dir")
      instructions="$agent_dir/instructions"
      files=""
      for f in AGENTS.md SOUL.md HEARTBEAT.md TOOLS.md; do
        [[ -f "$instructions/$f" ]] && files="$files $f"
      done
      echo "  Agent: $agent_id  [${files# }]"
    done
  fi
  echo
done
