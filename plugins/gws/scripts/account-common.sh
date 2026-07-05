#!/usr/bin/env bash
# Shared helpers for gws account scripts.
# Source this file — do not execute directly.

ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
DEFAULT_CONFIG="$HOME/.config/gws"
ACTIVE_FILE="$ACCOUNTS_BASE/.active"

# Resolve the active config directory.
# Priority: .active file > default config.
resolve_active_config() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    local label
    label=$(cat "$ACTIVE_FILE")
    local dir="$ACCOUNTS_BASE/$label"
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return
    fi
    echo "WARNING: .active points to '$label' but directory not found. Falling back to default." >&2
    rm -f "$ACTIVE_FILE"
  fi
  echo "$DEFAULT_CONFIG"
}

# Resolve the config directory for a specific account, given a label or email.
# Checks label directories first, then matches against each account.json email.
# Errors (exit 1) if no account matches — callers should not fall back silently.
resolve_config_for_account() {
  local wanted="$1"
  if [[ "$wanted" == "default" ]]; then
    echo "$DEFAULT_CONFIG"
    return
  fi
  if [[ -d "$ACCOUNTS_BASE/$wanted" ]]; then
    echo "$ACCOUNTS_BASE/$wanted"
    return
  fi
  local dir email
  for dir in "$ACCOUNTS_BASE"/*/; do
    [[ -d "$dir" && -f "$dir/account.json" ]] || continue
    email=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('email',''))" "$dir/account.json" 2>/dev/null || true)
    if [[ "$email" == "$wanted" ]]; then
      echo "${dir%/}"
      return
    fi
  done
  echo "ERROR: No gws account found matching '$wanted' (label or email)." >&2
  return 1
}

# Get the label of the active account.
resolve_active_label() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    local label
    label=$(cat "$ACTIVE_FILE")
    if [[ -d "$ACCOUNTS_BASE/$label" ]]; then
      echo "$label"
      return
    fi
  fi
  echo "default"
}
