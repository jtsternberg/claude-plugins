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

# HOTLINE_FORCE_HEADLESS=1 (or true/yes) makes us report "cmux unavailable"
# even when it is, so the dial skill takes the headless fallback path. Useful
# for debugging the headless transport, comparing behavior across modes, or
# forcing programmatic-credit usage when you want claude -p's structured
# stream-json output instead of cmux read-screen scraping.
case "${HOTLINE_FORCE_HEADLESS:-}" in
  1|true|TRUE|yes|YES) exit 1 ;;
esac

if ! command -v cmux &>/dev/null; then
  exit 1
fi

cmux ping &>/dev/null || exit 1
exit 0
