#!/usr/bin/env bash
# List all configured Google accounts.
# Usage: account-list.sh [--json]
# Output: Table of label, email, active status. With --json, outputs JSON array.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/account-common.sh"

JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ACTIVE_LABEL=$(resolve_active_label)

# Collect accounts
ACCOUNTS=()

# Include the default account (~/.config/gws)
if [[ -d "$DEFAULT_CONFIG" && -f "$DEFAULT_CONFIG/credentials.enc" ]]; then
  default_email=$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DEFAULT_CONFIG" gws auth status 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('user','unknown'))" 2>/dev/null || echo "unknown")
  default_active=false
  [[ "$ACTIVE_LABEL" == "default" ]] && default_active=true
  ACCOUNTS+=("default|$default_email|$default_active")
fi

for dir in "$ACCOUNTS_BASE"/*/; do
  [[ -d "$ACCOUNTS_BASE" && -d "$dir" ]] || continue
  label=$(basename "$dir")
  metadata="$dir/account.json"

  if [[ -f "$metadata" ]]; then
    email=$(python3 -c "import json; print(json.load(open('$metadata')).get('email','unknown'))" 2>/dev/null || echo "unknown")
  else
    email="unknown"
  fi

  active=false
  [[ "$label" == "$ACTIVE_LABEL" ]] && active=true

  ACCOUNTS+=("$label|$email|$active")
done

if [[ ${#ACCOUNTS[@]} -eq 0 ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo "[]"
  else
    echo "No accounts configured. Run account-add.sh <label> to add one." >&2
  fi
  exit 0
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json
accounts = []
for entry in '''$(printf '%s\n' "${ACCOUNTS[@]}")'''.strip().split('\n'):
    label, email, active = entry.split('|')
    accounts.append({'label': label, 'email': email, 'active': active == 'true'})
print(json.dumps(accounts))
"
else
  printf "%-15s %-35s %s\n" "LABEL" "EMAIL" "ACTIVE"
  printf "%-15s %-35s %s\n" "-----" "-----" "------"
  for entry in "${ACCOUNTS[@]}"; do
    IFS='|' read -r label email active <<< "$entry"
    marker=""
    [[ "$active" == "true" ]] && marker="*"
    printf "%-15s %-35s %s\n" "$label" "$email" "$marker"
  done
fi
