#!/usr/bin/env bash
# =============================================================================
# Surface Ready: block until a freshly-created cmux terminal surface (or a
# workspace's current surface) has its PTY attached AND its shell is actually
# executing input.
#
# `cmux send` is what attaches a surface's PTY — lazily, on the first send. That
# is the whole mechanism, and it is why this script's probe IS the attachment
# step rather than something that waits for one:
#
#   1. "Terminal surface not found" / "Failed to read terminal text" — every
#      `cmux read-screen` fails until something has sent to the surface.
#      Verified on cmux 0.64.22: a surface created with --focus false answers
#      `Error: internal_error: Failed to read terminal text` before its first
#      send and reads fine straight after one. So a readiness wait built on
#      read-screen alone can never succeed; the send has to come first.
#   2. Swallowed `\n` (fresh-PTY race) — the shell's startup banner ("Last
#      login: …") can print AFTER our typed command, eating the trailing
#      newline so `send "bash launch\n"` types the command but never runs it.
#      We round-trip an `echo <marker>` probe and re-send it periodically until
#      the marker appears as command OUTPUT (>=2 on-screen hits: the typed input
#      line + the executed echo line), proving the shell actually ran input.
#
# FOCUS IS NOT PART OF THIS. `cmux focus-pane` also attaches the PTY, eagerly,
# but it does so by MOVING THE USER'S FOCUS — and a user typing at that moment
# has their keystrokes land in the callee's shell, which is how a launch command
# became `rkebash /tmp/…` (2026-08-26). Focus buys ~0.1s and costs the user's
# input line, so this script never takes it (claude-plugins-r465.4).
#
# NET-NEW hotline infrastructure: the side-by-side path delegates entirely to
# cmux-cli's open-side-surface.sh (which has its own --wait-ready), but the
# --window and --detached placement paths are hotline-only — cmux-cli offers no
# standalone readiness helper for a surface or workspace we created ourselves. So
# this script exists to give both of them the same PTY-readiness guarantee. The
# probe algorithm mirrors cmux-cli's --wait-ready by necessity (it's the only
# correct way to detect a swallowed \n), but there is no callable cmux-cli
# equivalent to reuse here.
#
# Usage:
#   surface-ready.sh --surface <surface_ref> [--pane <pane_ref>] [--timeout <s>]
#   surface-ready.sh --workspace <workspace_ref> [--timeout <seconds>]
#
# --pane is accepted for compatibility and used only in diagnostics; nothing
# focuses it.
#
# Exit codes:
#   0   — ready (PTY attached and shell executing input)
#   2   — usage / dependency error
#   3   — timed out (target exists but never echoed the probe back)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

SURFACE=""
WORKSPACE=""
PANE=""
TIMEOUT=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)   SURFACE="${2:-}";   shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --pane)      PANE="${2:-}";      shift 2 ;;
    --timeout)   TIMEOUT="${2:-}";   shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "surface-ready: unknown option: $1" >&2; exit 2 ;;
  esac
done

# EXACTLY ONE target, and it must be non-empty. `cmux send --surface ""` does not
# fail — it delivers to the FOCUSED surface, which on 2026-08-26 meant probe
# echoes landing in an unrelated live claude session, twice. An unset handle is
# therefore a usage error here, never a default (claude-plugins-r465.7).
if [[ -n "$SURFACE" && -n "$WORKSPACE" ]]; then
  echo "surface-ready: pass --surface OR --workspace, not both" >&2
  exit 2
fi
if [[ -n "$SURFACE" ]]; then
  TARGET_FLAG="--surface"; TARGET="$SURFACE"
elif [[ -n "$WORKSPACE" ]]; then
  TARGET_FLAG="--workspace"; TARGET="$WORKSPACE"
else
  echo "surface-ready: --surface <ref> or --workspace <ref> is required (an empty handle would be delivered to the focused surface)" >&2
  exit 2
fi
command -v cmux >/dev/null 2>&1 || { echo "surface-ready: cmux not on PATH" >&2; exit 2; }

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
      echo "surface-ready: timed out after ${TIMEOUT}s for ${TARGET}${PANE:+ (${PANE})}."
      echo "  Possible causes:"
      echo "    • Shell still initializing (slow rc files, network mounts, login banner)"
      echo "    • Target running a non-shell program that doesn't echo input"
      echo "    • The handle names a surface that no longer exists"
    } >&2
    exit 3
  fi

  # (Re)send the probe every ~1s (5 * 0.2s) in case an earlier \n was swallowed
  # by the surface's startup output. Same marker each time — one landing is enough.
  #
  # Ctrl-U FIRST, every time. The input line is shared with the user, and a probe
  # concatenated onto three stray keystrokes produces `rkeecho __HOTLINE…` — an
  # error line that can itself satisfy the >=2-hit test below because the marker
  # appears in both the typed line and the shell's complaint about it.
  if (( attempt % 5 == 0 )); then
    cmux_clear_input_line "surface-ready probe" "$TARGET_FLAG" "$TARGET"
    cmux_send_live "surface-ready probe" "$TARGET_FLAG" "$TARGET" "echo ${marker}\n" \
      >/dev/null 2>&1 || true
  fi
  attempt=$((attempt + 1))
  sleep 0.2

  # The typed `echo MARKER` shows once as input; shell execution adds the output
  # line. >=2 hits => the shell actually ran the command (not just buffered it).
  #
  # Scroll-immune read (repl-state.sh): a plain read-screen would return the
  # user's scrolled viewport and this loop would spin to its ceiling against a
  # surface that was ready seconds ago.
  hits=$(cmux_read_live "surface-ready probe" "$TARGET_FLAG" "$TARGET" 200 \
         | grep -Fc "${marker}" || true)
  if [[ "${hits:-0}" -ge 2 ]]; then
    exit 0
  fi
done
