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
# This opener is hotline-net-new: cmux-cli's open-side-surface.sh only places a
# surface SIDE-BY-SIDE with the caller, never in an arbitrary find-or-create
# window, so there is nothing in cmux-cli to reuse for this. PTY readiness is
# delegated to the sibling surface-ready.sh so a just-created surface never
# drops the trailing \n of the launch command (fresh-PTY race) and never hits
# "Terminal surface not found" (PTY-not-attached).
#
# Everything here is created with --focus false. `cmux send` attaches the PTY on
# its own (verified on cmux 0.64.22: a --focus false workspace + surface answered
# a probe send and executed it in ~0.8s, with the user's focus untouched), so
# --focus true bought nothing here except moving the user's cursor into a callee's
# shell mid-keystroke (claude-plugins-r465.4).
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
  #
  # THE TITLE KEY IS `title`. `cmux new-workspace --name <text>` sets it and the
  # tree reports it as `title` — there is no `name` key on a workspace object, so
  # matching on `.name` matched nothing and EVERY `--window <name>` call fell
  # through to the create branch and opened another window (claude-plugins-3ako,
  # verified on cmux 0.64.22: two consecutive calls for the same name produced
  # window:4 and window:5, each with its own correctly-titled workspace). That is
  # the find half of find-or-create, and it is the whole point of the placement.
  # `.name` is kept as a fallback so a cmux that ever reports it still resolves.
  #
  # `read` returns non-zero on empty input (no match) — tolerate it under set -e.
  found_win=""; found_ws=""
  read -r found_win found_ws < <(cmux tree --all --json | jq -r --arg n "$WINDOW" '
    [ .windows[] as $win
      | $win.workspaces[]
      | select((.title // .name // "") == $n)
      | "\($win.ref) \(.ref)" ] | .[0] // empty') || true
  if [[ -n "${found_ws:-}" ]]; then
    target_win="$found_win"
    target_ws="$found_ws"
  else
    # Create a new window, then a titled workspace inside it.
    #
    # THE NEW WINDOW IS IDENTIFIED BY UUID AND TRANSLATED TO A REF THROUGH THE
    # TREE. `cmux list-windows` prints `* 0: <UUID> selected_workspace=<UUID>
    # workspaces=N` and `cmux current-window` prints a bare UUID — NEITHER emits
    # a `window:N` token, so a before/after grep for one came back empty on both
    # sides, the diff and its fallback both resolved to nothing, and this path
    # died at "could not determine new window ref" every time the named window
    # did not already exist. That killed `--window <name>` for its whole
    # find-or-create purpose (claude-plugins-3ako, verified on cmux 0.64.22).
    #
    # AND THE PRINTED INDEX IS NOT THE REF. list-windows index 0 is `window:1` in
    # the tree, so building `window:<printed index>` targets the WRONG window —
    # a callee would land in a bystander's window. `cmux tree --all --json
    # --id-format both` reports each window's `id` (UUID) next to its `ref`, and
    # it is the only place that mapping is available; every resolution below goes
    # through it.
    win_tree() { cmux tree --all --json --id-format both 2>/dev/null || true; }
    win_ids() { printf '%s' "$1" | jq -r '.windows[]?.id // empty' | sort -u; }

    before=$(win_ids "$(win_tree)")
    cmux new-window >/dev/null 2>&1 || { echo "open-window-surface: cmux new-window failed" >&2; exit 1; }
    tree_after=$(win_tree)
    # 1. The UUID that appeared. Immune to which window cmux focused.
    new_id=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$(win_ids "$tree_after")") | head -1)
    if [[ -n "$new_id" ]]; then
      target_win=$(printf '%s' "$tree_after" | jq -r --arg i "$new_id" \
        '.windows[]? | select(.id == $i) | .ref // empty' | head -1)
    fi
    # 2. The UUID `cmux current-window` prints, mapped through the same tree —
    #    new-window focuses what it creates. Case-insensitive because cmux emits
    #    uppercase UUIDs and a value that has been through another tool may not.
    if [[ -z "$target_win" ]]; then
      cur_id=$(cmux current-window 2>/dev/null | tr -d '[:space:]' || true)
      [[ -n "$cur_id" ]] && target_win=$(printf '%s' "$tree_after" | jq -r --arg i "$cur_id" \
        '.windows[]? | select(((.id // "") | ascii_downcase) == ($i | ascii_downcase)) | .ref // empty' | head -1)
    fi
    # 3. The tree's own idea of the current window.
    if [[ -z "$target_win" ]]; then
      target_win=$(printf '%s' "$tree_after" | jq -r \
        '.windows[]? | select(.current == true) | .ref // empty' | head -1)
    fi
    # A HARD ERROR, never a silent fallthrough. With target_win empty, every cmux
    # call below would resolve its missing target to the FOCUSED window and land
    # the callee in whatever the user is looking at.
    [[ -z "$target_win" ]] && { echo "open-window-surface: cmux new-window succeeded but its window ref could not be resolved from 'cmux tree --all --json --id-format both' (looked for a new window id, then the id 'cmux current-window' prints, then the tree's current window). Refusing to continue: without a window ref cmux would place the callee in whatever window has focus." >&2; exit 1; }

    ws_out=$(cmux new-workspace --name "$WINDOW" --window "$target_win" --focus false \
      ${CWD:+--cwd "$CWD"} 2>&1) || { echo "open-window-surface: new-workspace failed: $ws_out" >&2; exit 1; }
    target_ws=$(printf '%s' "$ws_out" | grep -oE 'workspace:[0-9]+' | head -1 || true)
    [[ -z "$target_ws" ]] && { echo "open-window-surface: could not parse new workspace ref: $ws_out" >&2; exit 1; }
    created_window=true
  fi
fi

# Land a fresh surface for the callee in the resolved workspace.
surf_args=(new-surface --type terminal --window "$target_win" --workspace "$target_ws" --focus false)
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
