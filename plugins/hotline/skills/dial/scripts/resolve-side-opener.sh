#!/usr/bin/env bash
# =============================================================================
# Resolve cmux-cli's canonical open-side-surface.sh — the single source of truth
# for side-by-side placement (split-vs-adjacent decision tree + --wait-ready PTY
# handling). Hotline does NOT carry a copy: it calls cmux-cli's script at runtime.
#
# Side-by-side placement runs ONLY under cmux. cmux being present does NOT
# guarantee the cmux-cli plugin is installed, though — so this resolver can
# legitimately come up empty. When it does, the dial skill falls back to the
# HEADLESS transport (cmux-without-cmux-cli is treated like no-cmux: the cmux
# side-by-side integration isn't available, so degrade the whole call to
# headless rather than to a detached tab).
#
# Both plugins live under the same plugins dir (in this repo and when installed
# separately), so the sibling path resolves in both layouts.
#
#   HOTLINE_OPEN_SIDE_SURFACE — explicit path override (skips the search).
#   HOTLINE_PLUGINS_DIR       — override the plugins-dir search root.
#
# Prints the resolved path to stdout and exits 0 on success; exits 1 if not found.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${HOTLINE_OPEN_SIDE_SURFACE:-}" ]]; then
  [[ -f "$HOTLINE_OPEN_SIDE_SURFACE" ]] && { printf '%s\n' "$HOTLINE_OPEN_SIDE_SURFACE"; exit 0; }
  exit 1
fi

plugins_dir="${HOTLINE_PLUGINS_DIR:-$SCRIPT_DIR/../../../..}"
for cand in \
  "$plugins_dir/cmux-cli/skills/using-cmux-cli/scripts/open-side-surface.sh" \
  "$plugins_dir"/*/skills/using-cmux-cli/scripts/open-side-surface.sh; do
  [[ -f "$cand" ]] && { printf '%s\n' "$cand"; exit 0; }
done

exit 1
