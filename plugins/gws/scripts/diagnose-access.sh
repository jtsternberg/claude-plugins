#!/usr/bin/env bash
# Diagnose why a Google Drive file/folder is inaccessible.
# Called on failure paths by gdoc-to-md and md-to-gdoc scripts.
# Usage: diagnose-access.sh <resource-id>
# Output: Actionable error message on stdout. Exits non-zero.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve active account config directory
if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
  _COMMON="$SCRIPT_DIR/account-common.sh"
  if [[ -f "$_COMMON" ]]; then
    source "$_COMMON"
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
  fi
fi

RESOURCE_ID="${1:?Usage: diagnose-access.sh <resource-id>}"

# Get authenticated email
AUTH_EMAIL=$(gws auth status 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('user','unknown'))" 2>/dev/null || echo "unknown")

# Get current account label if multi-account is configured
ACCOUNT_LABEL=""
if [[ -x "$SCRIPT_DIR/account-current.sh" ]]; then
  ACCOUNT_LABEL=$("$SCRIPT_DIR/account-current.sh" --label 2>/dev/null || true)
fi
ACCOUNT_INFO="$AUTH_EMAIL"
if [[ -n "$ACCOUNT_LABEL" && "$ACCOUNT_LABEL" != "default" ]]; then
  ACCOUNT_INFO="$AUTH_EMAIL (account: $ACCOUNT_LABEL)"
fi

# Check if other accounts are available
HAS_OTHER_ACCOUNTS=false
ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
if [[ -d "$ACCOUNTS_BASE" ]] && [[ $(find "$ACCOUNTS_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) -gt 1 ]]; then
  HAS_OTHER_ACCOUNTS=true
fi

# Attempt to fetch the resource and capture the full response (including errors)
RESPONSE=$(gws drive files get --params "{\"fileId\": \"$RESOURCE_ID\", \"fields\": \"name\"}" 2>&1 || true)

# Try to extract an HTTP error code from the response
ERROR_CODE=$(printf '%s' "$RESPONSE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('code',''))" 2>/dev/null || true)

SWITCH_HINT=""
if [[ "$HAS_OTHER_ACCOUNTS" == true ]]; then
  SWITCH_HINT=" Try switching accounts with account-switch.sh, or share the resource with '$AUTH_EMAIL'."
else
  SWITCH_HINT=" Try sharing it with '$AUTH_EMAIL', or switch accounts with 'gws auth login'."
fi

case "$ERROR_CODE" in
  404)
    echo "File/folder not found. You're authenticated as $ACCOUNT_INFO. This resource may belong to a different Google account.$SWITCH_HINT"
    ;;
  403)
    echo "Permission denied. You're authenticated as $ACCOUNT_INFO but don't have access to this resource. Ask the owner to share it with you."
    ;;
  401)
    echo "Authentication expired. Run 'gws auth login' to re-authenticate."
    ;;
  *)
    echo "Could not access resource '$RESOURCE_ID'. Authenticated as $ACCOUNT_INFO."
    echo "API response: $RESPONSE"
    ;;
esac

exit 1
