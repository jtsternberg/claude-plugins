#!/usr/bin/env bash
# Switch active Google account by label.
# Usage: account-switch.sh <label> [--env]
#   Default: prints export statement for eval (e.g. eval "$(account-switch.sh work)")
#   --env:   prints just the config dir path (for programmatic use)
# Output: Export statement or path on stdout. Messages on stderr.
set -euo pipefail

ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"

usage() {
  echo "Usage: $(basename "$0") <label> [--env]" >&2
  echo "  eval \"\$($(basename "$0") work)\"   # switch in current shell" >&2
  echo "  $(basename "$0") work --env         # just print config dir path" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage

LABEL="$1"
shift
ENV_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_ONLY=true; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

ACCOUNT_DIR="$ACCOUNTS_BASE/$LABEL"

if [[ ! -d "$ACCOUNT_DIR" ]]; then
  echo "ERROR: No account found with label '$LABEL'." >&2
  echo "Available accounts:" >&2
  if [[ -d "$ACCOUNTS_BASE" ]]; then
    for dir in "$ACCOUNTS_BASE"/*/; do
      [[ -d "$dir" ]] && echo "  $(basename "$dir")" >&2
    done
  else
    echo "  (none — run account-add.sh <label> to add one)" >&2
  fi
  exit 1
fi

# Verify credentials exist
if [[ ! -f "$ACCOUNT_DIR/credentials.enc" && ! -f "$ACCOUNT_DIR/credentials.json" ]]; then
  echo "ERROR: Account '$LABEL' exists but has no credentials. Re-run account-add.sh $LABEL." >&2
  exit 1
fi

if [[ "$ENV_ONLY" == true ]]; then
  echo "$ACCOUNT_DIR"
else
  echo "export GOOGLE_WORKSPACE_CLI_CONFIG_DIR=\"$ACCOUNT_DIR\""
fi

# Show confirmation on stderr
metadata="$ACCOUNT_DIR/account.json"
if [[ -f "$metadata" ]]; then
  email=$(python3 -c "import json; print(json.load(open('$metadata')).get('email','unknown'))" 2>/dev/null || echo "unknown")
  echo "Switched to account '$LABEL' ($email)." >&2
else
  echo "Switched to account '$LABEL'." >&2
fi
