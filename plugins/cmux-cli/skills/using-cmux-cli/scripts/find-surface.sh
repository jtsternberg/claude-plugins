#!/usr/bin/env bash
# find-surface — search cmux surfaces by workspace, title, or screen content.
#
# Discovery: `cmux tree --all --json`.
# Content:   `cmux read-screen --workspace <ws> --surface <s>` per candidate.
# Parsing:   jq (required).
#
# Terminal surfaces only when --content is used. Browser surfaces are
# enumerated but skipped for content search — use `cmux browser snapshot`
# for page DOM instead.

set -euo pipefail
# Downstream closed the pipe (e.g., `| head -n`) — not an error for us.
trap 'exit 0' PIPE
# User hit Ctrl-C — exit with the conventional 128+SIGINT code.
trap 'exit 130' INT

WORKSPACE_FILTER=""
CONTENT_PATTERN=""
TITLE_PATTERN=""
USE_REGEX=0
SCROLLBACK=0
LINES=500
OUTPUT_JSON=0
INCLUDE_SELF=0

usage() {
  cat <<'EOF'
find-surface — search cmux surfaces by workspace, title, or screen content.

Usage: find-surface [OPTIONS]

Options:
  -w, --workspace <name|ref>   Narrow to workspace. "workspace:N" = exact ref;
                                anything else = case-insensitive substring on title.
  -c, --content <pattern>      Match surface screen content.
  -t, --title <pattern>        Match surface title.
  -r, --regex                  Treat --content and --title as extended regex (ERE).
                                Default: case-insensitive substring.
  -s, --scrollback             Search scrollback in addition to visible viewport.
  -l, --lines <n>              Scrollback line limit (default 500). Implies -s.
      --json                   Emit a JSON array. Default: human-readable text.
      --include-self           Include the calling surface in results. Default is
                                to exclude it so agents don't match their own
                                transcript when searching for text.
  -h, --help                   Show this help.

With no filters, lists every surface in every workspace (excluding the caller).

Requires: cmux, jq.

Examples:
  find-surface                              # list every surface
  find-surface -w "cmux-cli skill"          # surfaces inside that workspace
  find-surface -w cmux                      # fuzzy: matches "cmux-cli skill"
  find-surface -w workspace:9               # exact ref
  find-surface -c "npm test"                # surfaces whose screen shows "npm test"
  find-surface -c "error" -s -l 1000        # include 1000 lines of scrollback
  find-surface -w debug -c "PANIC" --json   # scoped + machine-readable
  find-surface --json | jq -r '.[].surface_ref'

Output (text):
  workspace:9 "cmux-cli skill" -> surface:17 [terminal] "Debug session..." [matched: content]
    snippet: <first matching line>

Output (--json):
  [{"workspace_ref":"workspace:9","workspace_name":"cmux-cli skill",
    "surface_ref":"surface:17","surface_type":"terminal","surface_title":"...",
    "tty":"ttys208","pane_ref":"pane:11","window_ref":"window:1",
    "matched_on":["content"],"snippet":"..."}, ...]

Exit codes:
  0 = one or more matches emitted (or clean SIGPIPE on `| head`)
  1 = no matches
  2 = usage / dependency error
  130 = interrupted (Ctrl-C)
EOF
}

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)  WORKSPACE_FILTER="${2:-}"; shift 2 ;;
    -c|--content)    CONTENT_PATTERN="${2:-}"; shift 2 ;;
    -t|--title)      TITLE_PATTERN="${2:-}"; shift 2 ;;
    -r|--regex)      USE_REGEX=1; shift ;;
    -s|--scrollback) SCROLLBACK=1; shift ;;
    -l|--lines)      SCROLLBACK=1; LINES="${2:-500}"; shift 2 ;;
    --json)          OUTPUT_JSON=1; shift ;;
    --include-self)  INCLUDE_SELF=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "find-surface: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Preflight ---
command -v cmux >/dev/null 2>&1 || { echo "find-surface: cmux not on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "find-surface: jq required (brew install jq)" >&2; exit 2; }

# --- Discover caller's own surface so we can exclude it by default ---
# `cmux identify --json` returns caller.surface_ref when invoked from inside a
# cmux terminal. Outside cmux (or if the socket is down) we silently skip the
# exclusion — there's nothing to exclude.
SELF_SURFACE_REF=""
if [[ $INCLUDE_SELF -eq 0 ]]; then
  if identify_json=$(cmux identify --json 2>/dev/null); then
    SELF_SURFACE_REF=$(printf '%s' "$identify_json" | jq -r '.caller.surface_ref // empty' 2>/dev/null || true)
  fi
fi

# --- Match helper (bash 3 compatible) ---
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

matches() {
  # matches <haystack> <needle>
  local haystack="$1" needle="$2"
  if [[ $USE_REGEX -eq 1 ]]; then
    [[ "$haystack" =~ $needle ]]
  else
    local h n
    h=$(to_lower "$haystack")
    n=$(to_lower "$needle")
    [[ "$h" == *"$n"* ]]
  fi
}

# --- Flatten `cmux tree --all --json` into TSV rows via jq ---
# Columns: ws_ref \t ws_name \t surf_ref \t surf_type \t surf_title \t tty \t pane_ref \t window_ref
flatten_tree() {
  cmux tree --all --json | jq -r --arg wsf "$WORKSPACE_FILTER" '
    def ws_match(f):
      if f == "" then true
      elif (f | startswith("workspace:")) then .ref == f
      else ((.title // "") | ascii_downcase | contains(f | ascii_downcase))
      end;
    .windows[] as $win
    | $win.workspaces[]
    | select(ws_match($wsf))
    | . as $ws
    | .panes[] as $pane
    | $pane.surfaces[]
    | [
        $ws.ref, ($ws.title // ""),
        .ref, (.type // ""), (.title // ""),
        (.tty // ""), $pane.ref, $win.ref
      ]
    | @tsv
  '
}

# --- Collect results ---
results_file=$(mktemp)
trap 'rm -f "$results_file"' EXIT

while IFS=$'\t' read -r ws_ref ws_name s_ref s_type s_title tty pane_ref win_ref; do
  # Skip the calling surface unless --include-self was passed. Without this,
  # an agent searching for text in "the other tab" matches its own transcript.
  if [[ -n "$SELF_SURFACE_REF" && "$s_ref" == "$SELF_SURFACE_REF" ]]; then
    continue
  fi

  matched=""
  snippet=""

  if [[ -n "$TITLE_PATTERN" ]]; then
    if matches "$s_title" "$TITLE_PATTERN"; then
      matched="title"
    else
      continue
    fi
  fi

  if [[ -n "$CONTENT_PATTERN" ]]; then
    # read-screen only makes sense on terminal surfaces.
    if [[ "$s_type" != "terminal" ]]; then
      continue
    fi
    screen_args=(--workspace "$ws_ref" --surface "$s_ref")
    if [[ $SCROLLBACK -eq 1 ]]; then
      screen_args+=(--scrollback --lines "$LINES")
    fi
    if ! screen=$(cmux read-screen "${screen_args[@]}" 2>/dev/null); then
      continue
    fi
    [[ -z "$screen" ]] && continue
    if [[ $USE_REGEX -eq 1 ]]; then
      line=$(printf '%s\n' "$screen" | grep -E -m1 -- "$CONTENT_PATTERN" 2>/dev/null || true)
    else
      line=$(printf '%s\n' "$screen" | grep -i -F -m1 -- "$CONTENT_PATTERN" 2>/dev/null || true)
    fi
    [[ -z "$line" ]] && continue
    matched="${matched:+$matched,}content"
    snippet="$line"
  fi

  if [[ -z "$TITLE_PATTERN" && -z "$CONTENT_PATTERN" ]]; then
    matched="listed"
  fi

  # Snippets may contain tabs/newlines that would break our TSV — collapse them.
  safe_snippet=$(printf '%s' "$snippet" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ws_ref" "$ws_name" "$s_ref" "$s_type" "$s_title" \
    "$tty" "$pane_ref" "$win_ref" "$matched" "$safe_snippet" \
    >> "$results_file"
done < <(flatten_tree)

# --- Output ---
if [[ ! -s "$results_file" ]]; then
  if [[ $OUTPUT_JSON -eq 1 ]]; then
    echo "[]"
  else
    echo "No surfaces matched." >&2
  fi
  exit 1
fi

if [[ $OUTPUT_JSON -eq 1 ]]; then
  jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({
        workspace_ref:  .[0],
        workspace_name: .[1],
        surface_ref:    .[2],
        surface_type:   .[3],
        surface_title:  .[4],
        tty:            .[5],
        pane_ref:       .[6],
        window_ref:     .[7],
        matched_on:    (if ((.[8] // "") == "") then ["listed"] else (.[8] | split(",")) end),
        snippet:       (.[9] // "")
      })
  ' < "$results_file"
else
  # 2>/dev/null + `|| exit 0` keeps output clean when the consumer closes
  # the pipe early (e.g. `| head -n`). Without it, bash's printf emits
  # "write error: Broken pipe" before our PIPE trap fires.
  while IFS=$'\t' read -r ws_ref ws_name s_ref s_type s_title tty pane_ref win_ref matched snippet; do
    type_tag="[${s_type}]"
    if [[ "$matched" == "listed" ]]; then
      printf '%s "%s" -> %s %s "%s"\n' "$ws_ref" "$ws_name" "$s_ref" "$type_tag" "$s_title" 2>/dev/null || exit 0
    else
      printf '%s "%s" -> %s %s "%s" [matched: %s]\n' "$ws_ref" "$ws_name" "$s_ref" "$type_tag" "$s_title" "$matched" 2>/dev/null || exit 0
    fi
    if [[ -n "$snippet" ]]; then
      printf '    snippet: %s\n' "$snippet" 2>/dev/null || exit 0
    fi
  done < "$results_file"
fi
