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
# Both plugins live under the same plugins dir, but the exact depth and shape of
# that dir differs by host. This resolver must work across at least:
#   - repo / Claude install:  <plugins>/hotline/skills/dial/scripts   (sibling:
#                             <plugins>/cmux-cli/skills/using-cmux-cli/...)
#   - Codex cache:  <root>/jtsternberg/hotline/<version>/skills/dial/scripts
#                   (sibling: <root>/jtsternberg/cmux-cli/<version>/skills/...)
# So we cannot assume a fixed relative depth OR a version-less sibling. Instead we
# walk up from this script's dir and, at each ancestor, try patterns that tolerate
# an optional version directory on either side. First (highest-version) hit wins.
#
#   HOTLINE_OPEN_SIDE_SURFACE — explicit path override (skips the search).
#   HOTLINE_PLUGINS_DIR       — pin the search root (still tolerates version dirs).
#
# Prints the resolved path to stdout and exits 0 on success; exits 1 if not found.
# =============================================================================
set -euo pipefail
shopt -s nullglob   # non-matching globs expand to nothing, not the literal pattern

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${HOTLINE_OPEN_SIDE_SURFACE:-}" ]]; then
  [[ -f "$HOTLINE_OPEN_SIDE_SURFACE" ]] && { printf '%s\n' "$HOTLINE_OPEN_SIDE_SURFACE"; exit 0; }
  exit 1
fi

# Try a single search root: return the highest-version open-side-surface.sh under
# it, tolerating an optional version dir between the plugin name and skills/.
# Patterns are ordered most- to least-specific; within a pattern, sort -V picks
# the newest version when several are cached side by side.
try_root() {
  local root="$1" cand matches
  for pat in \
    "$root/cmux-cli/skills/using-cmux-cli/scripts/open-side-surface.sh" \
    "$root"/cmux-cli/*/skills/using-cmux-cli/scripts/open-side-surface.sh \
    "$root"/*/skills/using-cmux-cli/scripts/open-side-surface.sh \
    "$root"/*/*/skills/using-cmux-cli/scripts/open-side-surface.sh; do
    matches=$(printf '%s\n' $pat 2>/dev/null | sort -V)
    while IFS= read -r cand; do
      [[ -n "$cand" && -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
    done <<< "$matches"
  done
  return 1
}

# Explicit root override wins (but still tolerant of version-dir layouts).
if [[ -n "${HOTLINE_PLUGINS_DIR:-}" ]]; then
  try_root "$HOTLINE_PLUGINS_DIR" && exit 0
  exit 1
fi

# Walk up from this script's dir. The first ancestor that has a cmux-cli sibling
# is the real plugins root — in repo that's ~4 up, under Codex's versioned cache
# it's ~5 up, so a bounded walk covers both without hard-coding the depth.
dir="$SCRIPT_DIR"
for _ in 1 2 3 4 5 6 7; do
  dir="$(cd "$dir/.." && pwd)"
  try_root "$dir" && exit 0
  [[ "$dir" == "/" ]] && break
done

exit 1
