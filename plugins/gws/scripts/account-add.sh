#!/usr/bin/env bash
# Add a new Google account with a label for multi-account switching.
# Usage: account-add.sh <label>
# Opens a browser for OAuth login, stores credentials in a labeled config dir.
# Output: JSON with label, email, and config_dir on stdout. Progress on stderr.
set -euo pipefail

ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
DEFAULT_CONFIG="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-$HOME/.config/gws}"

usage() {
  echo "Usage: $(basename "$0") <label>" >&2
  echo "  label: short name for the account (e.g. 'work', 'personal')" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage

LABEL="$1"

# Validate label: alphanumeric, hyphens, underscores only
if [[ ! "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: Label must be alphanumeric (hyphens and underscores allowed)." >&2
  exit 1
fi

ACCOUNT_DIR="$ACCOUNTS_BASE/$LABEL"

if [[ -d "$ACCOUNT_DIR" && -f "$ACCOUNT_DIR/credentials.enc" ]]; then
  echo "Account '$LABEL' already exists. To re-authenticate, remove $ACCOUNT_DIR first." >&2
  exit 1
fi

# Create account directory
mkdir -p "$ACCOUNT_DIR"

# Copy client_secret.json from default config (the OAuth app config is shared)
if [[ -f "$DEFAULT_CONFIG/client_secret.json" ]]; then
  cp "$DEFAULT_CONFIG/client_secret.json" "$ACCOUNT_DIR/client_secret.json"
  echo "Copied OAuth client config from default gws config." >&2
else
  echo "WARNING: No client_secret.json found at $DEFAULT_CONFIG/client_secret.json" >&2
  echo "You may need to run 'gws auth setup' first, or copy client_secret.json manually." >&2
fi

# Run gws auth login, capturing output to extract and open the OAuth URL.
# gws auth login prints the URL to stderr when it can't open a browser itself.
echo "Starting Google account login (label: $LABEL)..." >&2

AUTH_LOG=$(mktemp)
trap 'rm -f "$AUTH_LOG"' EXIT

GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$ACCOUNT_DIR" gws auth login 2>&1 | tee "$AUTH_LOG" >&2 &
LOGIN_PID=$!

# Wait briefly for the URL to appear, then open it
sleep 2
AUTH_URL=$(grep -oE 'https://accounts\.google\.com/o/oauth2/auth[^ ]+' "$AUTH_LOG" 2>/dev/null || true)

if [[ -n "$AUTH_URL" ]]; then
  echo "Opening OAuth URL in browser..." >&2
  if command -v open >/dev/null 2>&1; then
    open "$AUTH_URL"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$AUTH_URL"
  else
    echo "Please open this URL manually:" >&2
    echo "$AUTH_URL" >&2
  fi
fi

# Wait for gws auth login to complete
wait "$LOGIN_PID" || true

# Verify login succeeded by checking auth status
AUTH_JSON=$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$ACCOUNT_DIR" gws auth status 2>/dev/null || true)
EMAIL=$(printf '%s' "$AUTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('user',''))" 2>/dev/null || true)

if [[ -z "$EMAIL" ]]; then
  echo "WARNING: Login may not have completed. Run 'gws auth status' to check." >&2
  EMAIL="unknown"
fi

# Store metadata for listing
python3 -c "import json; print(json.dumps({'label':'$LABEL','email':'$EMAIL'}))" > "$ACCOUNT_DIR/account.json"

echo "Account '$LABEL' added ($EMAIL)." >&2

# Output structured result
python3 -c "
import json
print(json.dumps({
  'label': '$LABEL',
  'email': '$EMAIL',
  'config_dir': '$ACCOUNT_DIR'
}))
"
