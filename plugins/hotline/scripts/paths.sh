#!/usr/bin/env bash
# =============================================================================
# Hotline Paths: Resolve all plugin script directories
#
# Source this at the top of any hotline script, or run it to print paths.
#
# Usage (in a script):
#   source "$(dirname "$0")/../scripts/paths.sh"  # from skills/*/scripts/
#   source "$(dirname "$0")/paths.sh"              # from scripts/
#
# Usage (standalone):
#   bash plugins/hotline/scripts/paths.sh          # prints all paths
# =============================================================================

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: source paths.sh (sets HOTLINE_ROOT, HOTLINE_SCRIPTS, etc.)"
  exit 0
fi

# Resolve plugin root regardless of where we're called from
HOTLINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOTLINE_SCRIPTS="${HOTLINE_ROOT}/scripts"
HOTLINE_DIAL_SCRIPTS="${HOTLINE_ROOT}/skills/dial/scripts"
HOTLINE_PICKUP_SCRIPTS="${HOTLINE_ROOT}/skills/pickup/scripts"

# If run directly (not sourced), print paths
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "HOTLINE_ROOT=${HOTLINE_ROOT}"
  echo "HOTLINE_SCRIPTS=${HOTLINE_SCRIPTS}"
  echo "HOTLINE_DIAL_SCRIPTS=${HOTLINE_DIAL_SCRIPTS}"
  echo "HOTLINE_PICKUP_SCRIPTS=${HOTLINE_PICKUP_SCRIPTS}"
fi
