#!/usr/bin/env bash
# open-side-surface — open a new surface side-by-side with the caller's (or
# the user's focused) pane. Encapsulates the case-1 decision tree so agents
# don't have to hand-roll it.
#
# Algorithm:
#   1. `cmux identify --json` → subject's pane_ref + workspace_ref.
#   2. `cmux tree --all --json` → enumerate panes in that workspace.
#   3. If subject's workspace has only ONE pane:
#        → `cmux new-pane --direction right --type <t> --workspace <ws> [--url]`
#          (new-pane is used instead of new-split because it supports both
#           terminal and browser types.)
#      Else pick the adjacent pane (subject's index + 1, or -1 if rightmost):
#        → `cmux new-surface --pane <adjacent> --type <t> [--url]`
#          (reuses the real estate the user has already allocated instead of
#           creating a third pane column.)
#   4. Parse `OK surface:<n> pane:<p> workspace:<w>` from cmux's output.

set -euo pipefail
trap 'exit 0' PIPE
trap 'exit 130' INT

SUBJECT="caller"     # caller | focused
SURFACE_TYPE="terminal"
URL=""
OUTPUT_JSON=0

usage() {
  cat <<'EOF'
open-side-surface — open a new surface side-by-side with the caller's
(or the user's focused) pane.

Usage: open-side-surface [OPTIONS]

Options:
      --caller           Open next to the script caller's own pane (default).
                          Use when the agent wants a sibling for its own use.
      --focused          Open next to the pane the user is currently looking at.
                          Use when the user says "next to what I'm looking at".
      --type <t>         Surface type: terminal (default) or browser.
      --url <url>        URL for browser surfaces. Ignored for terminal.
      --json             Emit a JSON object on success. Default: human-readable.
  -h, --help             Show this help.

The script decides between `cmux new-pane --direction right` (when the
subject's workspace has only one pane) and `cmux new-surface --pane <adj>`
(when there's already an adjacent pane to reuse).

Output (text):
  OK surface:34 pane:12 workspace:9 (via new-surface)

Output (--json):
  {"surface_ref":"surface:34","pane_ref":"pane:12","workspace_ref":"workspace:9",
   "mode":"new-surface","subject":"caller"}

Requires: cmux, jq.

Exit codes:
  0 = surface created
  1 = cmux command failed (see stderr)
  2 = usage / dependency / context error
  130 = interrupted (Ctrl-C)
EOF
}

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller)   SUBJECT="caller"; shift ;;
    --focused)  SUBJECT="focused"; shift ;;
    --type)     SURFACE_TYPE="${2:-}"; shift 2 ;;
    --url)      URL="${2:-}"; shift 2 ;;
    --json)     OUTPUT_JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "open-side-surface: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$SURFACE_TYPE" != "terminal" && "$SURFACE_TYPE" != "browser" ]]; then
  echo "open-side-surface: --type must be 'terminal' or 'browser' (got: $SURFACE_TYPE)" >&2
  exit 2
fi

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
subject_surf=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].surface_ref // empty')

if [[ -z "$subject_pane" || -z "$subject_ws" ]]; then
  echo "open-side-surface: could not resolve $SUBJECT.pane_ref / workspace_ref from identify" >&2
  exit 2
fi

# --- Enumerate panes in subject's workspace (ordered, with indexes) ---
# TSV: pane_ref \t index
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

# Read into parallel arrays (bash 3 compatible — no readarray/mapfile).
pane_refs=()
pane_indexes=()
while IFS=$'\t' read -r p_ref p_idx; do
  pane_refs+=("$p_ref")
  pane_indexes+=("$p_idx")
done <<< "$panes_tsv"

pane_count=${#pane_refs[@]}

# Find subject's position in the ordered pane list
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
  # No adjacent pane exists — create one to the right.
  mode="new-pane"
  args=(new-pane --direction right --type "$SURFACE_TYPE" --workspace "$subject_ws")
  [[ "$SURFACE_TYPE" == "browser" && -n "$URL" ]] && args+=(--url "$URL")
else
  # Pick adjacent: prefer the pane immediately to the right (idx+1), else left.
  adj_pos=$((my_pos + 1))
  if [[ $adj_pos -ge $pane_count ]]; then
    adj_pos=$((my_pos - 1))
  fi
  adjacent_pane="${pane_refs[$adj_pos]}"
  mode="new-surface"
  args=(new-surface --pane "$adjacent_pane" --type "$SURFACE_TYPE")
  [[ "$SURFACE_TYPE" == "browser" && -n "$URL" ]] && args+=(--url "$URL")
fi

# --- Execute, capture, parse ---
if ! out=$(cmux "${args[@]}" 2>&1); then
  echo "open-side-surface: cmux ${args[*]} failed:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# Parse `OK surface:<n> pane:<p> workspace:<w>` (order may vary slightly).
new_surface=$(printf '%s' "$out" | grep -oE 'surface:[0-9]+' | head -1 || true)
new_pane=$(printf    '%s' "$out" | grep -oE 'pane:[0-9]+'    | head -1 || true)
new_ws=$(printf      '%s' "$out" | grep -oE 'workspace:[0-9]+' | head -1 || true)

# Fall back to what we know if the output surprises us.
[[ -z "$new_pane" && "$mode" == "new-surface" ]] && new_pane="$adjacent_pane"
[[ -z "$new_ws" ]] && new_ws="$subject_ws"

if [[ -z "$new_surface" ]]; then
  echo "open-side-surface: created a surface but could not parse its ref from cmux output:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# --- Output ---
if [[ $OUTPUT_JSON -eq 1 ]]; then
  jq -n \
    --arg surface "$new_surface" \
    --arg pane    "$new_pane" \
    --arg ws      "$new_ws" \
    --arg mode    "$mode" \
    --arg subject "$SUBJECT" \
    --arg type    "$SURFACE_TYPE" \
    --arg url     "$URL" \
    '{surface_ref: $surface, pane_ref: $pane, workspace_ref: $ws,
      mode: $mode, subject: $subject, surface_type: $type,
      url: (if $url == "" then null else $url end)}'
else
  printf 'OK %s %s %s (via %s, next to %s %s)\n' \
    "$new_surface" "$new_pane" "$new_ws" "$mode" "$SUBJECT" "$subject_pane"
fi
