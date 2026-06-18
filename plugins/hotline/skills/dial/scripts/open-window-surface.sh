#!/usr/bin/env bash
# open-window-surface — land a new terminal surface in a SPECIFIC cmux window,
# find-or-create. Used by the hotline `--window <name|ref>` placement override
# to group callees by project.
#
# cmux windows are not directly name-addressable (`cmux new-window` takes no
# name and `cmux list-windows` reports name:null). So we identify a "named
# window" by a WORKSPACE titled <name> living inside it — workspaces ARE
# nameable (`cmux new-workspace --name`). This makes `--window <name>`
# idempotent: the first call creates a window + a workspace tab titled <name>;
# later calls find that workspace and reuse its window.
#
# Resolution:
#   • <name|ref> matching ^window:<n>$ or a bare integer → treated as a window
#     ref/index; the surface lands in that window's first workspace.
#   • otherwise <name> is matched against existing workspace titles across all
#     windows. Found → reuse that workspace. Not found → new-window +
#     new-workspace --name <name>, then land the surface there.
#
# PTY readiness is delegated to the sibling surface-ready.sh (shared with the
# side-by-side path) so a just-created surface never drops the trailing \n of
# the launch command (fresh-PTY race) and never hits "Terminal surface not
# found" (PTY-not-attached). New surfaces/workspaces are created with
# --focus true, the surface-mode equivalent of `new-workspace --focus true`.
#
# Usage:
#   open-window-surface.sh --window <name|ref> [--working-directory <cwd>]
#                          [--wait-ready] [--wait-ready-timeout <s>] [--json]
#
# Output (--json): same shape as open-side-surface.sh, plus "created" (bool)
#   reporting whether a new window was made.
#
# Exit codes:
#   0 = surface created (ready field reports PTY readiness when --wait-ready)
#   1 = cmux command failed (see stderr)
#   2 = usage / dependency / context error
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WINDOW=""
CWD=""
OUTPUT_JSON=0
WAIT_READY=0
WAIT_READY_TIMEOUT=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)             WINDOW="${2:-}"; shift 2 ;;
    --working-directory)  CWD="${2:-}";    shift 2 ;;
    --json)               OUTPUT_JSON=1;   shift ;;
    --wait-ready)         WAIT_READY=1;    shift ;;
    --wait-ready-timeout) WAIT_READY_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "open-window-surface: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$WINDOW" ]] && { echo "open-window-surface: --window <name|ref> is required" >&2; exit 2; }
command -v cmux >/dev/null 2>&1 || { echo "open-window-surface: cmux not on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "open-window-surface: jq required" >&2; exit 2; }

created_window=false
target_win=""
target_ws=""

if [[ "$WINDOW" =~ ^window:[0-9]+$ || "$WINDOW" =~ ^[0-9]+$ ]]; then
  # Ref/index form: target the window directly; use its first workspace.
  target_win="$WINDOW"
  [[ "$WINDOW" =~ ^[0-9]+$ ]] && target_win="window:$WINDOW"
  target_ws=$(cmux tree --all --json | jq -r --arg w "$target_win" '
    .windows[] | select(.ref == $w) | .workspaces[0].ref // empty')
  if [[ -z "$target_ws" ]]; then
    echo "open-window-surface: window '$target_win' not found or has no workspace" >&2
    exit 1
  fi
else
  # Name form: find a workspace titled <name> anywhere; reuse its window.
  # `read` returns non-zero on empty input (no match) — tolerate it under set -e.
  found_win=""; found_ws=""
  read -r found_win found_ws < <(cmux tree --all --json | jq -r --arg n "$WINDOW" '
    [ .windows[] as $win
      | $win.workspaces[]
      | select(.name == $n)
      | "\($win.ref) \(.ref)" ] | .[0] // empty') || true
  if [[ -n "${found_ws:-}" ]]; then
    target_win="$found_win"
    target_ws="$found_ws"
  else
    # Create a new window, then a titled workspace inside it.
    before=$(cmux list-windows 2>/dev/null | grep -oE 'window:[0-9]+' | sort -u || true)
    cmux new-window >/dev/null 2>&1 || { echo "open-window-surface: cmux new-window failed" >&2; exit 1; }
    after=$(cmux list-windows 2>/dev/null | grep -oE 'window:[0-9]+' | sort -u || true)
    target_win=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
    if [[ -z "$target_win" ]]; then
      # Fall back to the current window if the diff didn't pin it down.
      target_win=$(cmux current-window 2>/dev/null | grep -oE 'window:[0-9]+' | head -1 || true)
    fi
    [[ -z "$target_win" ]] && { echo "open-window-surface: could not determine new window ref" >&2; exit 1; }

    ws_out=$(cmux new-workspace --name "$WINDOW" --window "$target_win" --focus true \
      ${CWD:+--cwd "$CWD"} 2>&1) || { echo "open-window-surface: new-workspace failed: $ws_out" >&2; exit 1; }
    target_ws=$(printf '%s' "$ws_out" | grep -oE 'workspace:[0-9]+' | head -1 || true)
    [[ -z "$target_ws" ]] && { echo "open-window-surface: could not parse new workspace ref: $ws_out" >&2; exit 1; }
    created_window=true
  fi
fi

# Land a fresh surface for the callee in the resolved workspace.
surf_args=(new-surface --type terminal --window "$target_win" --workspace "$target_ws" --focus true)
[[ -n "$CWD" ]] && surf_args+=(--working-directory "$CWD")
if ! out=$(cmux "${surf_args[@]}" 2>&1); then
  echo "open-window-surface: cmux ${surf_args[*]} failed:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

new_surface=$(printf '%s' "$out" | grep -oE 'surface:[0-9]+' | head -1 || true)
new_pane=$(printf    '%s' "$out" | grep -oE 'pane:[0-9]+'    | head -1 || true)
new_ws=$(printf      '%s' "$out" | grep -oE 'workspace:[0-9]+' | head -1 || true)
[[ -z "$new_ws" ]] && new_ws="$target_ws"

if [[ -z "$new_surface" ]]; then
  echo "open-window-surface: created a surface but could not parse its ref:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

ready_status="skipped"
if [[ $WAIT_READY -eq 1 ]]; then
  if bash "$SCRIPT_DIR/surface-ready.sh" --surface "$new_surface" --pane "$new_pane" \
       --timeout "$WAIT_READY_TIMEOUT" 2>/dev/null; then
    ready_status="ready"
  else
    ready_status="timeout"
  fi
fi

if [[ $OUTPUT_JSON -eq 1 ]]; then
  jq -n \
    --arg surface "$new_surface" --arg pane "$new_pane" --arg ws "$new_ws" \
    --arg win "$target_win" --arg ready "$ready_status" \
    --argjson created "$created_window" \
    '{surface_ref: $surface, pane_ref: $pane, workspace_ref: $ws,
      window_ref: $win, mode: "window", created: $created, ready: $ready}'
else
  printf 'OK %s %s %s window=%s created=%s ready=%s\n' \
    "$new_surface" "$new_pane" "$new_ws" "$target_win" "$created_window" "$ready_status"
fi
