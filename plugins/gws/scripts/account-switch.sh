#!/usr/bin/env bash
# Switch active Google account by label.
# Usage: account-switch.sh <label>
# Persists the choice to ~/.config/gws-accounts/.active so it survives
# across shell sessions and agent Bash() calls.
# Output: Confirmation on stderr. JSON result on stdout with --json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/account-common.sh"

JSON_OUTPUT=false

usage() {
  echo "Usage: $(basename "$0") <label> [--json]" >&2
  echo "  $(basename "$0") work      # switch to labeled account" >&2
  echo "  $(basename "$0") default   # switch back to default account" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage

LABEL="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ "$LABEL" == "default" ]]; then
  # Switching to default = remove the .active file
  rm -f "$ACTIVE_FILE"
  EMAIL=$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DEFAULT_CONFIG" gws auth status 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('user','unknown'))" 2>/dev/null || echo "unknown")
  echo "Switched to default account ($EMAIL)." >&2

  if [[ "$JSON_OUTPUT" == true ]]; then
    python3 -c "
import json
print(json.dumps({
  'label': 'default',
  'email': '$EMAIL',
  'config_dir': '$DEFAULT_CONFIG'
}))
"
  fi
  exit 0
fi

ACCOUNT_DIR="$ACCOUNTS_BASE/$LABEL"

if [[ ! -d "$ACCOUNT_DIR" ]]; then
  echo "ERROR: No account found with label '$LABEL'." >&2
  echo "Available accounts:" >&2
  echo "  default" >&2
  if [[ -d "$ACCOUNTS_BASE" ]]; then
    for dir in "$ACCOUNTS_BASE"/*/; do
      [[ -d "$dir" ]] && echo "  $(basename "$dir")" >&2
    done
  fi
  exit 1
fi

# Verify credentials exist
if [[ ! -f "$ACCOUNT_DIR/credentials.enc" && ! -f "$ACCOUNT_DIR/credentials.json" ]]; then
  echo "ERROR: Account '$LABEL' exists but has no credentials. Re-run account-add.sh $LABEL." >&2
  exit 1
fi

# Persist the switch
mkdir -p "$ACCOUNTS_BASE"
echo "$LABEL" > "$ACTIVE_FILE"

# Show confirmation on stderr
metadata="$ACCOUNT_DIR/account.json"
EMAIL="unknown"
if [[ -f "$metadata" ]]; then
  EMAIL=$(python3 -c "import json; print(json.load(open('$metadata')).get('email','unknown'))" 2>/dev/null || echo "unknown")
fi
echo "Switched to account '$LABEL' ($EMAIL)." >&2

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json
print(json.dumps({
  'label': '$LABEL',
  'email': '$EMAIL',
  'config_dir': '$ACCOUNT_DIR'
}))
"
fi
