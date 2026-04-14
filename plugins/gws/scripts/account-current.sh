#!/usr/bin/env bash
# Show the currently active Google account.
# Usage: account-current.sh [--json] [--email] [--label]
# Output: Account info on stdout.
set -euo pipefail

ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
ACTIVE_CONFIG="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-$HOME/.config/gws}"

JSON_OUTPUT=false
EMAIL_ONLY=false
LABEL_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    --email) EMAIL_ONLY=true; shift ;;
    --label) LABEL_ONLY=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Resolve the active config dir to an absolute path
REAL_ACTIVE=$(cd "$ACTIVE_CONFIG" 2>/dev/null && pwd || echo "$ACTIVE_CONFIG")

# Check if the active config matches a labeled account
LABEL=""
EMAIL=""

if [[ -d "$ACCOUNTS_BASE" ]]; then
  for dir in "$ACCOUNTS_BASE"/*/; do
    [[ -d "$dir" ]] || continue
    real_dir=$(cd "$dir" && pwd)
    if [[ "$real_dir" == "$REAL_ACTIVE" ]]; then
      LABEL=$(basename "$dir")
      metadata="$dir/account.json"
      if [[ -f "$metadata" ]]; then
        EMAIL=$(python3 -c "import json; print(json.load(open('$metadata')).get('email',''))" 2>/dev/null || true)
      fi
      break
    fi
  done
fi

# If no label matched, get email from gws auth status
if [[ -z "$EMAIL" ]]; then
  EMAIL=$(gws auth status 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('user','unknown'))" 2>/dev/null || echo "unknown")
fi

# Default label for the default config dir
if [[ -z "$LABEL" ]]; then
  LABEL="default"
fi

if [[ "$EMAIL_ONLY" == true ]]; then
  echo "$EMAIL"
elif [[ "$LABEL_ONLY" == true ]]; then
  echo "$LABEL"
elif [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json
print(json.dumps({
  'label': '$LABEL',
  'email': '$EMAIL',
  'config_dir': '$REAL_ACTIVE'
}))
"
else
  echo "Account: $LABEL"
  echo "Email:   $EMAIL"
  echo "Config:  $REAL_ACTIVE"
fi
