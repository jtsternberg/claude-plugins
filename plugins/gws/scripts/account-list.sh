#!/usr/bin/env bash
# List all configured Google accounts.
# Usage: account-list.sh [--json]
# Output: Table of label, email, active status. With --json, outputs JSON array.
set -euo pipefail

ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
ACTIVE_CONFIG="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-$HOME/.config/gws}"
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$ACCOUNTS_BASE" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo "[]"
  else
    echo "No accounts configured. Run account-add.sh <label> to add one." >&2
  fi
  exit 0
fi

# Collect accounts
ACCOUNTS=()
for dir in "$ACCOUNTS_BASE"/*/; do
  [[ -d "$dir" ]] || continue
  label=$(basename "$dir")
  metadata="$dir/account.json"

  if [[ -f "$metadata" ]]; then
    email=$(python3 -c "import json; print(json.load(open('$metadata')).get('email','unknown'))" 2>/dev/null || echo "unknown")
  else
    email="unknown"
  fi

  # Check if this is the active account
  active=false
  real_dir=$(cd "$dir" && pwd)
  real_active=$(cd "$ACTIVE_CONFIG" 2>/dev/null && pwd || echo "")
  if [[ "$real_dir" == "$real_active" ]]; then
    active=true
  fi

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
