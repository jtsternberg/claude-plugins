#!/usr/bin/env bash
# Diagnose why a Google Drive file/folder is inaccessible.
# Called on failure paths by gdoc-to-md and md-to-gdoc scripts.
# Usage: diagnose-access.sh <resource-id>
# Output: Actionable error message on stdout. Exits non-zero.
set -euo pipefail

RESOURCE_ID="${1:?Usage: diagnose-access.sh <resource-id>}"

# Get authenticated email
AUTH_EMAIL=$(gws auth status 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('email','unknown'))" 2>/dev/null || echo "unknown")

# Attempt to fetch the resource and capture the full response (including errors)
RESPONSE=$(gws drive files get --params "{\"fileId\": \"$RESOURCE_ID\", \"fields\": \"name\"}" 2>&1 || true)

# Try to extract an HTTP error code from the response
ERROR_CODE=$(printf '%s' "$RESPONSE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('code',''))" 2>/dev/null || true)

case "$ERROR_CODE" in
  404)
    echo "File/folder not found. You're authenticated as '$AUTH_EMAIL'. This resource may belong to a different Google account. Try sharing it with '$AUTH_EMAIL', or switch accounts with 'gws auth login'."
    ;;
  403)
    echo "Permission denied. You're authenticated as '$AUTH_EMAIL' but don't have access to this resource. Ask the owner to share it with you."
    ;;
  401)
    echo "Authentication expired. Run 'gws auth login' to re-authenticate."
    ;;
  *)
    echo "Could not access resource '$RESOURCE_ID'. Authenticated as '$AUTH_EMAIL'."
    echo "API response: $RESPONSE"
    ;;
esac

exit 1
