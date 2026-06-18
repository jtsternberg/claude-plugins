#!/usr/bin/env bash
# =============================================================================
# Surface Ready: block until a freshly-created cmux terminal surface has its
# PTY attached AND its shell is actually executing input.
#
# This is the surface-mode equivalent of the new-workspace path's
# `cmux new-workspace --focus true` requirement. It solves the two
# fresh-surface footguns that previously only `cmux new-workspace --focus true`
# avoided, now that hotline lands callees in side-by-side / windowed surfaces:
#
#   1. "Terminal surface not found" — `cmux read-screen` / `cmux send` fail
#      until the PTY backend attaches. `cmux focus-pane --pane <pane>` forces
#      attachment.
#   2. Swallowed `\n` (fresh-PTY race) — the shell's startup banner ("Last
#      login: …") can print AFTER our typed command, eating the trailing
#      newline so `send "bash launch\n"` types the command but never runs it.
#      We round-trip an `echo <marker>` probe and re-send it periodically until
#      the marker appears as command OUTPUT (≥2 on-screen hits: the typed input
#      line + the executed echo line), proving the shell actually ran input.
#
# The probe logic is lifted from the cmux-cli plugin's open-side-surface.sh
# `--wait-ready` handling so hotline has a SINGLE, unit-testable readiness
# primitive shared by both the side-by-side and --window placement paths.
#
# Usage:
#   surface-ready.sh --surface <surface_ref> --pane <pane_ref> [--timeout <seconds>]
#
# Exit codes:
#   0   — surface ready (PTY attached and shell executing input)
#   2   — usage / dependency error
#   3   — timed out (surface exists but never echoed the probe back)
# =============================================================================
set -euo pipefail

SURFACE=""
PANE=""
TIMEOUT=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface) SURFACE="${2:-}"; shift 2 ;;
    --pane)    PANE="${2:-}";    shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "surface-ready: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SURFACE" ]]; then
  echo "surface-ready: --surface <ref> is required" >&2
  exit 2
fi
command -v cmux >/dev/null 2>&1 || { echo "surface-ready: cmux not on PATH" >&2; exit 2; }

# Force the PTY backend to attach so read-screen / send actually work. Without
# this the first read-screen on a just-created surface returns "Terminal
# surface not found". Best-effort: focus-pane needs a pane ref; if we only have
# a surface ref the probe loop below still works once cmux attaches the PTY.
[[ -n "$PANE" ]] && cmux focus-pane --pane "$PANE" >/dev/null 2>&1 || true

# A nonce that survives across re-sends so we only need >=1 successful round
# trip. Vary by pid + seconds + RANDOM so concurrent calls don't collide.
nonce="$(date +%s)$$${RANDOM:-0}"
marker="__HOTLINE_PTYREADY_${nonce}__"
start_ts=$(date +%s)
attempt=0

while :; do
  now_ts=$(date +%s)
  if (( now_ts - start_ts >= TIMEOUT )); then
    {
      echo "surface-ready: timed out after ${TIMEOUT}s for ${SURFACE}${PANE:+ (${PANE})}."
      echo "  Possible causes:"
      echo "    • PTY backend never attached (try: cmux focus-pane --pane ${PANE:-<pane>})"
      echo "    • Shell still initializing (slow rc files, network mounts, login banner)"
      echo "    • Surface running a non-shell program that doesn't echo input"
    } >&2
    exit 3
  fi

  # (Re)send the probe every ~1s (5 * 0.2s) in case an earlier \n was swallowed
  # by the surface's startup output. Same marker each time — one landing is enough.
  if (( attempt % 5 == 0 )); then
    cmux send --surface "$SURFACE" "echo ${marker}\n" >/dev/null 2>&1 || true
  fi
  attempt=$((attempt + 1))
  sleep 0.2

  # The typed `echo MARKER` shows once as input; shell execution adds the output
  # line. >=2 hits => the shell actually ran the command (not just buffered it).
  hits=$(cmux read-screen --surface "$SURFACE" --scrollback --lines 200 2>/dev/null \
         | grep -Fc "${marker}" || true)
  if [[ "${hits:-0}" -ge 2 ]]; then
    exit 0
  fi
done
