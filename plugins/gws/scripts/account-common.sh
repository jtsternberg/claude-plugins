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
