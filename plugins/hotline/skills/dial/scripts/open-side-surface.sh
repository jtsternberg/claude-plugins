#!/usr/bin/env bash
# open-side-surface — open a new terminal surface side-by-side with the caller's
# (or the user's focused) pane in the SAME cmux window.
#
# VENDORED from the cmux-cli plugin's
# skills/using-cmux-cli/scripts/open-side-surface.sh. Hotline carries its own
# copy because the cmux-cli plugin may not be installed alongside hotline — the
# dial SKILL only *optionally* leans on the `/cmux-cli:using-cmux-cli` skill, so
# the transport must not hard-depend on that plugin's files existing on disk.
# Keep the split-vs-adjacent decision tree in sync with the upstream script.
#
# Two intentional divergences from upstream:
#   • `--wait-ready` delegates to the sibling surface-ready.sh so hotline has a
#     single, unit-testable PTY-readiness primitive shared with the --window
#     placement path.
#   • On a --wait-ready timeout we still emit the surface JSON (with
#     ready:"timeout") and exit 0, so the caller always learns the surface_ref
#     and can clean it up instead of orphaning it.
#
# Algorithm:
#   1. `cmux identify --json` → subject's pane_ref + workspace_ref + window_ref.
#   2. `cmux tree --all --json` → enumerate panes in that workspace.
#   3. If subject's workspace has only ONE pane:
#        → `cmux new-pane --direction right --type terminal --workspace <ws>`
#      Else pick the adjacent pane (subject's index + 1, or -1 if rightmost):
#        → `cmux new-surface --pane <adjacent> --type terminal`
#   4. Parse `OK surface:<n> pane:<p> workspace:<w>` from cmux's output.

set -euo pipefail
trap 'exit 0' PIPE
trap 'exit 130' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBJECT="caller"     # caller | focused
OUTPUT_JSON=0
WAIT_READY=0
WAIT_READY_TIMEOUT=8

usage() {
  cat <<'EOF'
open-side-surface — open a new terminal surface side-by-side with the caller's
(or the user's focused) pane.

Usage: open-side-surface [OPTIONS]

Options:
      --caller           Open next to the script caller's own pane (default).
      --focused          Open next to the pane the user is currently looking at.
      --json             Emit a JSON object on success. Default: human-readable.
      --wait-ready       Block until the PTY is attached and the shell is
                          actually executing input (delegates to surface-ready.sh).
      --wait-ready-timeout <seconds>
                          Override the --wait-ready timeout (default: 8).
  -h, --help             Show this help.

Output (--json):
  {"surface_ref":"surface:34","pane_ref":"pane:12","workspace_ref":"workspace:9",
   "window_ref":"window:2","mode":"new-surface","subject":"caller","ready":"ready"}

Exit codes:
  0 = surface created (ready field reports PTY readiness when --wait-ready given)
  1 = cmux command failed (see stderr)
  2 = usage / dependency / context error
  130 = interrupted (Ctrl-C)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller)   SUBJECT="caller"; shift ;;
    --focused)  SUBJECT="focused"; shift ;;
    --json)     OUTPUT_JSON=1; shift ;;
    --wait-ready) WAIT_READY=1; shift ;;
    --wait-ready-timeout) WAIT_READY_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "open-side-surface: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Preflight ---
command -v cmux >/dev/null 2>&1 || { echo "open-side-surface: cmux not on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "open-side-surface: jq required (brew install jq)" >&2; exit 2; }

# --- Resolve subject ---
if ! identify_json=$(cmux identify --json 2>/dev/null); then
  echo "open-side-surface: 'cmux identify' failed — are you inside cmux? is the socket reachable?" >&2
  exit 2
fi

subject_pane=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].pane_ref // empty')
subject_ws=$(printf  '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].workspace_ref // empty')
subject_win=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].window_ref // empty')

if [[ -z "$subject_pane" || -z "$subject_ws" ]]; then
  echo "open-side-surface: could not resolve $SUBJECT.pane_ref / workspace_ref from identify" >&2
  exit 2
fi

# --- Enumerate panes in subject's workspace (ordered, with indexes) ---
panes_tsv=$(cmux tree --all --json | jq -r \
  --arg win "$subject_win" --arg ws "$subject_ws" '
    .windows[]
    | select(.ref == $win)
    | .workspaces[]
    | select(.ref == $ws)
    | .panes
    | sort_by(.index)
    | .[]
    | [.ref, (.index | tostring)]
    | @tsv
  ')

if [[ -z "$panes_tsv" ]]; then
  echo "open-side-surface: no panes found in $subject_ws (impossible?)" >&2
  exit 2
fi

pane_refs=()
while IFS=$'\t' read -r p_ref _p_idx; do
  pane_refs+=("$p_ref")
done <<< "$panes_tsv"

pane_count=${#pane_refs[@]}

my_pos=-1
for i in "${!pane_refs[@]}"; do
  if [[ "${pane_refs[$i]}" == "$subject_pane" ]]; then
    my_pos=$i
    break
  fi
done
if [[ $my_pos -lt 0 ]]; then
  echo "open-side-surface: subject pane $subject_pane not present in workspace pane list (stale state?)" >&2
  exit 2
fi

# --- Decide and execute ---
mode=""
if [[ $pane_count -eq 1 ]]; then
  mode="new-pane"
  args=(new-pane --direction right --type terminal --workspace "$subject_ws")
else
  adj_pos=$((my_pos + 1))
  if [[ $adj_pos -ge $pane_count ]]; then
    adj_pos=$((my_pos - 1))
  fi
  adjacent_pane="${pane_refs[$adj_pos]}"
  mode="new-surface"
  args=(new-surface --pane "$adjacent_pane" --type terminal)
fi

if ! out=$(cmux "${args[@]}" 2>&1); then
  echo "open-side-surface: cmux ${args[*]} failed:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

new_surface=$(printf '%s' "$out" | grep -oE 'surface:[0-9]+' | head -1 || true)
new_pane=$(printf    '%s' "$out" | grep -oE 'pane:[0-9]+'    | head -1 || true)
new_ws=$(printf      '%s' "$out" | grep -oE 'workspace:[0-9]+' | head -1 || true)

[[ -z "$new_pane" && "$mode" == "new-surface" ]] && new_pane="$adjacent_pane"
[[ -z "$new_ws" ]] && new_ws="$subject_ws"

if [[ -z "$new_surface" ]]; then
  echo "open-side-surface: created a surface but could not parse its ref from cmux output:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# --- Optional: wait for PTY readiness (shared primitive) ---
ready_status="skipped"
if [[ $WAIT_READY -eq 1 ]]; then
  if bash "$SCRIPT_DIR/surface-ready.sh" --surface "$new_surface" --pane "$new_pane" \
       --timeout "$WAIT_READY_TIMEOUT" 2>/dev/null; then
    ready_status="ready"
  else
    # Surface exists but never confirmed ready. Report it anyway (exit 0) so the
    # caller has the ref to clean up — never orphan a surface on a timeout.
    ready_status="timeout"
  fi
fi

# --- Output ---
if [[ $OUTPUT_JSON -eq 1 ]]; then
  jq -n \
    --arg surface "$new_surface" \
    --arg pane    "$new_pane" \
    --arg ws      "$new_ws" \
    --arg win     "$subject_win" \
    --arg mode    "$mode" \
    --arg subject "$SUBJECT" \
    --arg ready   "$ready_status" \
    '{surface_ref: $surface, pane_ref: $pane, workspace_ref: $ws,
      window_ref: (if $win == "" then null else $win end),
      mode: $mode, subject: $subject, ready: $ready}'
else
  printf 'OK %s %s %s (via %s, next to %s %s) ready=%s\n' \
    "$new_surface" "$new_pane" "$new_ws" "$mode" "$SUBJECT" "$subject_pane" "$ready_status"
fi
