#!/usr/bin/env bash
# Show the currently active Google account.
# Usage: account-current.sh [--json] [--email] [--label]
# Output: Account info on stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/account-common.sh"

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

LABEL=$(resolve_active_label)
ACTIVE_CONFIG_DIR=$(resolve_active_config)

# Get email from the active account
EMAIL=$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$ACTIVE_CONFIG_DIR" gws auth status 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('user','unknown'))" 2>/dev/null || echo "unknown")

REAL_ACTIVE=$(cd "$ACTIVE_CONFIG_DIR" 2>/dev/null && pwd || echo "$ACTIVE_CONFIG_DIR")

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
