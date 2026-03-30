#!/usr/bin/env bash
# =============================================================================
# Check CMUX: Detect if CMUX is available and responsive
#
# Exit 0 if cmux is available, 1 otherwise.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: check-cmux.sh"
  echo ""
  echo "Detects if CMUX is available and responsive."
  echo "Exit 0 if cmux is available, exit 1 if not."
  exit 0
fi

if ! command -v cmux &>/dev/null; then
  exit 1
fi

cmux ping &>/dev/null || exit 1
exit 0
