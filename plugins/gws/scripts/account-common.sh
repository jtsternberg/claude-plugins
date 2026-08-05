#!/usr/bin/env bash
# Shared helpers for gws account scripts.
# Source this file — do not execute directly.

ACCOUNTS_BASE="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
DEFAULT_CONFIG="$HOME/.config/gws"
ACTIVE_FILE="$ACCOUNTS_BASE/.active"

# Resolve the active config directory.
# Priority: .active file > default config.
#
# A dangling .active (pointing at a directory that no longer exists) warns and
# falls back, but must NOT delete the file. This used to `rm -f "$ACTIVE_FILE"`
# as self-healing, which was destructive on a *read* path: nearly every
# account-aware script calls this, most capture stdout and discard stderr, so
# the warning was invisible — and once the file was gone the warning could never
# fire again. The user's account selection was destroyed silently, and every
# subsequent Google call ran as the default (typically personal) identity with no
# trace of why. Warning about a recoverable state beats erasing the evidence.
# auth-preflight.sh turns this into a hard stop so the wrong identity is never
# used silently.
resolve_active_config() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    local label
    label=$(cat "$ACTIVE_FILE")
    local dir="$ACCOUNTS_BASE/$label"
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return
    fi
    # State the fact only. Callers decide what to do: auth-preflight.sh refuses
    # to proceed, so promising a fallback here would contradict it.
    echo "WARNING: .active selects '$label' but $dir does not exist." >&2
  fi
  echo "$DEFAULT_CONFIG"
}

# Print the label named by .active when its directory is missing; empty
# otherwise. Lets callers distinguish "nothing selected" from "selection points
# somewhere that no longer exists" — different problems with different fixes.
resolve_dangling_label() {
  [[ -f "$ACTIVE_FILE" ]] || return 0
  local label
  label=$(cat "$ACTIVE_FILE")
  [[ -d "$ACCOUNTS_BASE/$label" ]] || echo "$label"
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
