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
WAIT_READY=0
WAIT_READY_TIMEOUT=5

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
      --wait-ready       For terminal surfaces, block until the PTY is attached
                          and the shell is actually executing input. Forces
                          PTY attachment (cmux focus-pane) and round-trips a
                          probe (echo <marker>) to verify execution. No-op
                          for browser surfaces.
      --wait-ready-timeout <seconds>
                          Override the --wait-ready timeout (default: 5).
  -h, --help             Show this help.

The script decides between `cmux new-pane --direction right` (when the
subject's workspace has only one pane) and `cmux new-surface --pane <adj>`
(when there's already an adjacent pane to reuse).

Output (text):
  OK surface:34 pane:12 workspace:9 (via new-surface)
  surface_id: F73756CC-...        # the UUID to target by

Output (--json): carries both the stable UUID (*_id — pass these to commands)
and the positional ref (*_ref — display only):
  {"surface_ref":"surface:34","surface_id":"F73756CC-...",
   "pane_ref":"pane:12","pane_id":"...","workspace_ref":"workspace:9","workspace_id":"...",
   "mode":"new-surface","subject":"caller","surface_type":"terminal","url":null,"ready":"ready"}

Requires: cmux, jq.

Exit codes:
  0 = surface created (and ready, if --wait-ready)
  1 = cmux command failed (see stderr)
  2 = usage / dependency / context error
  3 = --wait-ready timed out (surface exists but PTY never echoed probe)
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
    --wait-ready) WAIT_READY=1; shift ;;
    --wait-ready-timeout) WAIT_READY_TIMEOUT="${2:-}"; shift 2 ;;
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
# A freshly-spawned or just-moved caller surface can be momentarily unqueryable
# by `cmux identify` (it returns empty pane_ref/workspace_ref for the subject
# before cmux has registered the surface's current placement). That's a race,
# not a hard error, so retry a few times before giving up. `cmux identify`
# already derives workspace_ref from the live surface — the inherited
# CMUX_WORKSPACE_ID env var going stale after a move does NOT affect it — so a
# short retry is sufficient to ride out the registration lag.
subject_pane=""; subject_ws=""; subject_win=""; subject_surf=""
for attempt in 1 2 3 4 5; do
  if identify_json=$(cmux identify --json 2>/dev/null); then
    subject_pane=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].pane_ref // empty')
    subject_ws=$(printf  '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].workspace_ref // empty')
    subject_win=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].window_ref // empty')
    subject_surf=$(printf '%s' "$identify_json" | jq -r --arg s "$SUBJECT" '.[$s].surface_ref // empty')
    [[ -n "$subject_pane" && -n "$subject_ws" ]] && break
  fi
  [[ $attempt -lt 5 ]] && sleep 0.4
done

if [[ -z "${identify_json:-}" ]]; then
  echo "open-side-surface: 'cmux identify' failed — are you inside cmux? is the socket reachable?" >&2
  exit 2
fi

if [[ -z "$subject_pane" || -z "$subject_ws" ]]; then
  echo "open-side-surface: could not resolve $SUBJECT.pane_ref / workspace_ref from identify (retried 5×; caller surface not registered?)" >&2
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

# --- Resolve stable UUIDs for the new surface ---
# The `OK ...` line only gives positional refs, which renumber as surfaces open
# and close. Look the new surface up in a fresh `--id-format both` tree so we can
# hand callers UUIDs (the `.id` fields) to target by — and use them ourselves for
# the readiness probes below. If lookup fails, we fall back to refs so behavior
# is never worse than before.
new_surface_id=""; new_pane_id=""; new_ws_id=""
tree_both=$(cmux tree --all --json --id-format both 2>/dev/null || true)
if [[ -n "$tree_both" ]]; then
  read -r new_surface_id new_pane_id new_ws_id < <(
    printf '%s' "$tree_both" | jq -r --arg s "$new_surface" '
      .windows[].workspaces[] as $ws
      | $ws.panes[].surfaces[]
      | select(.ref == $s)
      | "\(.id // "") \(.pane_id // "") \($ws.id // "")"' 2>/dev/null | head -1
  )
fi
# Prefer UUIDs; fall back to the parsed refs when resolution came up empty.
surface_handle="${new_surface_id:-$new_surface}"
pane_handle="${new_pane_id:-$new_pane}"

# --- Optional: wait for PTY readiness ---
#
# Solves two known footguns on freshly-spawned terminal surfaces:
#   1. `read-screen` returns "Terminal surface not found" until the PTY backend
#      attaches. `cmux focus-pane --pane <new_pane>` forces attachment.
#   2. The shell's `\n` gets swallowed by startup output, so `send "foo\n"` types
#      `foo` but never executes it. We round-trip an `echo <marker>` probe and
#      wait until the marker appears as command output (not just typed input).
#
# Re-sends the probe periodically — if a `\n` is swallowed by init, a later
# resend will land cleanly. Same nonce across resends; we only need ≥1 hit.
ready_status="skipped"
if [[ $WAIT_READY -eq 1 ]]; then
  if [[ "$SURFACE_TYPE" != "terminal" ]]; then
    ready_status="n/a"
  else
    # Force the PTY backend to attach so read-screen / send actually work.
    cmux focus-pane --pane "$pane_handle" >/dev/null 2>&1 || true

    nonce="$(date +%s)$$${RANDOM:-0}"
    marker="__CMUX_PTYREADY_${nonce}__"
    start_ts=$(date +%s)
    ready_status="timeout"
    attempt=0

    while :; do
      now_ts=$(date +%s)
      elapsed=$((now_ts - start_ts))
      if (( elapsed >= WAIT_READY_TIMEOUT )); then
        break
      fi

      # (Re)send the probe every ~1s in case earlier sends were swallowed.
      if (( attempt % 5 == 0 )); then
        cmux send --surface "$surface_handle" "echo ${marker}\n" >/dev/null 2>&1 || true
      fi
      attempt=$((attempt + 1))
      sleep 0.2

      # The typed `echo MARKER` echoes back as input (1 hit); shell execution
      # adds the output line (2nd hit). >=2 hits => the shell actually ran it.
      hits=$(cmux read-screen --surface "$surface_handle" --scrollback --lines 200 2>/dev/null \
             | grep -Fc "${marker}" || true)
      if [[ "${hits:-0}" -ge 2 ]]; then
        ready_status="ready"
        break
      fi
    done

    if [[ "$ready_status" != "ready" ]]; then
      {
        echo "open-side-surface: --wait-ready timed out after ${WAIT_READY_TIMEOUT}s for $new_surface ($new_pane)."
        echo "  Possible causes:"
        echo "    • PTY backend never attached (try: cmux focus-pane --pane $pane_handle)"
        echo "    • Shell still initializing (slow rc files, network mounts, login banner)"
        echo "    • Surface running a non-shell program that doesn't echo input"
      } >&2
      exit 3
    fi
  fi
fi

# --- Output ---
if [[ $OUTPUT_JSON -eq 1 ]]; then
  # *_id are the stable UUIDs — pass these to follow-up commands (send,
  # read-screen, close-surface, ...). *_ref are positional labels for display.
  jq -n \
    --arg surface    "$new_surface" \
    --arg surface_id "$new_surface_id" \
    --arg pane       "$new_pane" \
    --arg pane_id    "$new_pane_id" \
    --arg ws         "$new_ws" \
    --arg ws_id      "$new_ws_id" \
    --arg mode       "$mode" \
    --arg subject    "$SUBJECT" \
    --arg type       "$SURFACE_TYPE" \
    --arg url        "$URL" \
    --arg ready      "$ready_status" \
    '{surface_ref: $surface, surface_id: (if $surface_id == "" then null else $surface_id end),
      pane_ref: $pane, pane_id: (if $pane_id == "" then null else $pane_id end),
      workspace_ref: $ws, workspace_id: (if $ws_id == "" then null else $ws_id end),
      mode: $mode, subject: $subject, surface_type: $type,
      url: (if $url == "" then null else $url end),
      ready: $ready}'
else
  printf 'OK %s %s %s (via %s, next to %s %s)\n' \
    "$new_surface" "$new_pane" "$new_ws" "$mode" "$SUBJECT" "$subject_pane"
  # Print the UUID to target by (falls back to the ref if lookup came up empty).
  printf 'surface_id: %s\n' "$surface_handle"
fi
