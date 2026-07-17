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
AUTO_QUERY=""
USE_REGEX=0
SCROLLBACK=0
LINES=500
OUTPUT_JSON=0
INCLUDE_SELF=0

usage() {
  cat <<'EOF'
find-surface — search cmux surfaces by workspace, title, or screen content.

Usage: find-surface [QUERY] [OPTIONS]

A bare QUERY (no flag) is the "just find it" path: matches by title first
(cheap — one tree call, no screen reads), and only if nothing matches does it
fall back to a content scan. Use it when the user names a surface, e.g.:
  find-surface "hotline: claude-plugins -> Automating"

Title matching (-t and the QUERY title pass) is decoration-tolerant: leading
status glyphs (the busy/idle star, spinners) and surrounding whitespace are
stripped from BOTH sides before comparing, so pasting a tab label verbatim —
glyph and all — still matches even after the glyph has changed.

Options:
  -w, --workspace <name|ref>   Narrow to workspace. "workspace:N" = exact ref;
                                anything else = case-insensitive substring on title.
  -c, --content <pattern>      Match surface screen content.
  -t, --title <pattern>        Match surface title (decoration-tolerant; see above).
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
  find-surface "hotline: … Automating"      # bare query: title-first, content fallback
  find-surface                              # list every surface
  find-surface -w "cmux-cli skill"          # surfaces inside that workspace
  find-surface -w cmux                      # fuzzy: matches "cmux-cli skill"
  find-surface -w workspace:9               # exact ref
  find-surface -c "npm test"                # surfaces whose screen shows "npm test"
  find-surface -c "error" -s -l 1000        # include 1000 lines of scrollback
  find-surface -w debug -c "PANIC" --json   # scoped + machine-readable
  find-surface --json | jq -r '.[].surface_id'   # UUIDs to target by

Output (text):
  workspace:9 "cmux-cli skill" -> surface:17 [terminal] "Debug session..." [matched: content]
    surface_id: F73756CC-...  workspace_id: DE8FA1E0-...
    snippet: <first matching line>

Output (--json): each result carries both the stable UUID (*_id — pass these to
commands) and the positional ref (*_ref — display only):
  [{"workspace_ref":"workspace:9","workspace_id":"DE8FA1E0-...","workspace_name":"cmux-cli skill",
    "surface_ref":"surface:17","surface_id":"F73756CC-...","surface_type":"terminal","surface_title":"...",
    "tty":"ttys208","pane_ref":"pane:11","pane_id":"...","window_ref":"window:1","window_id":"...",
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
    --)              shift; [[ $# -gt 0 ]] && { AUTO_QUERY="$1"; shift; } ;;
    -*)              echo "find-surface: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)               if [[ -n "$AUTO_QUERY" ]]; then
                       echo "find-surface: multiple bare queries given ('$AUTO_QUERY', '$1'); pass one, or use -t/-c" >&2; exit 2
                     fi
                     AUTO_QUERY="$1"; shift ;;
  esac
done

# --- Preflight ---
command -v cmux >/dev/null 2>&1 || { echo "find-surface: cmux not on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "find-surface: jq required (brew install jq)" >&2; exit 2; }

# --- Discover caller's own surface so we can exclude it by default ---
# Match on the caller's stable UUID, not its positional ref: `--id-format both`
# gives us caller.surface_id (the UUID). $CMUX_SURFACE_ID is the same UUID and is
# our fallback when identify is unavailable. Outside cmux (or if the socket is
# down) we silently skip the exclusion — there's nothing to exclude.
SELF_SURFACE_ID="${CMUX_SURFACE_ID:-}"
if [[ $INCLUDE_SELF -eq 0 ]]; then
  if identify_json=$(cmux identify --json --id-format both 2>/dev/null); then
    id_from_identify=$(printf '%s' "$identify_json" | jq -r '.caller.surface_id // empty' 2>/dev/null || true)
    [[ -n "$id_from_identify" ]] && SELF_SURFACE_ID="$id_from_identify"
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

# Strip leading decoration (status glyphs, spinners, whitespace) and trailing
# whitespace from a surface title, so a title copied off a tab — where the
# leading glyph reflects transient busy/idle state — still matches after the
# glyph has changed or vanished. `[^[:alnum:]]` runs consume the multibyte
# glyph bytes; we stop at the first alphanumeric character.
normalize_title() { printf '%s' "$1" | sed 's/^[^[:alnum:]]*//; s/[[:space:]]*$//'; }

title_matches() {
  # title_matches <surface_title> <needle>
  local haystack="$1" needle="$2"
  if [[ $USE_REGEX -eq 1 ]]; then
    # Regex mode: caller is explicit — match the raw title, no normalization.
    [[ "$haystack" =~ $needle ]]
  else
    local h n
    h=$(to_lower "$(normalize_title "$haystack")")
    n=$(to_lower "$(normalize_title "$needle")")
    [[ "$h" == *"$n"* ]]
  fi
}

# --- Flatten `cmux tree --all --json --id-format both` into TSV rows via jq ---
# We request `--id-format both` so every node carries its stable UUID (the `.id`
# field) alongside its positional `.ref`. Callers should target by UUID; refs are
# included only for human-readable display. Column order:
#   ws_ref \t ws_id \t ws_name \t surf_ref \t surf_id \t surf_type \t surf_title
#   \t tty \t pane_ref \t pane_id \t window_ref \t window_id
flatten_tree() {
  cmux tree --all --json --id-format both | jq -r --arg wsf "$WORKSPACE_FILTER" '
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
        $ws.ref, ($ws.id // ""), ($ws.title // ""),
        .ref, (.id // ""), (.type // ""), (.title // ""),
        (.tty // ""), $pane.ref, ($pane.id // ""), $win.ref, ($win.id // "")
      ]
    | @tsv
  '
}

# --- Collect results ---
results_file=$(mktemp)
trap 'rm -f "$results_file"' EXIT

# Populate $results_file from the current TITLE_PATTERN / CONTENT_PATTERN /
# WORKSPACE_FILTER. Truncates first, so it is safe to call more than once
# (auto-mode runs it for a title pass, then a content pass).
collect_results() {
  : > "$results_file"
while IFS=$'\t' read -r ws_ref ws_id ws_name s_ref s_id s_type s_title tty pane_ref pane_id win_ref win_id; do
  # Skip the calling surface unless --include-self was passed. Match by UUID so
  # a renumbered ref can't accidentally include (or miss) our own surface.
  if [[ -n "$SELF_SURFACE_ID" && "$s_id" == "$SELF_SURFACE_ID" ]]; then
    continue
  fi

  matched=""
  snippet=""

  if [[ -n "$TITLE_PATTERN" ]]; then
    if title_matches "$s_title" "$TITLE_PATTERN"; then
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
    screen_args=(--workspace "$ws_id" --surface "$s_id")
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ws_ref" "$ws_id" "$ws_name" "$s_ref" "$s_id" "$s_type" "$s_title" \
    "$tty" "$pane_ref" "$pane_id" "$win_ref" "$win_id" "$matched" "$safe_snippet" \
    >> "$results_file"
done < <(flatten_tree)
}

# --- Run the search ---
# Auto mode: a bare QUERY with no explicit -t/-c tries a title pass first (cheap,
# no read-screen) and only falls back to a content scan if the title pass is dry.
# Explicit -t/-c always win over a stray positional.
if [[ -n "$AUTO_QUERY" && -z "$TITLE_PATTERN" && -z "$CONTENT_PATTERN" ]]; then
  TITLE_PATTERN="$AUTO_QUERY"
  collect_results
  if [[ ! -s "$results_file" ]]; then
    TITLE_PATTERN=""
    CONTENT_PATTERN="$AUTO_QUERY"
    collect_results
  fi
else
  collect_results
fi

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
  # surface_id / workspace_id / pane_id / window_id are the stable UUIDs — pass
  # these to any follow-up command (read-screen, send, close-surface, ...). The
  # *_ref fields are positional labels for display only.
  jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({
        workspace_ref:  .[0],
        workspace_id:   .[1],
        workspace_name: .[2],
        surface_ref:    .[3],
        surface_id:     .[4],
        surface_type:   .[5],
        surface_title:  .[6],
        tty:            .[7],
        pane_ref:       .[8],
        pane_id:        .[9],
        window_ref:     .[10],
        window_id:      .[11],
        matched_on:    (if ((.[12] // "") == "") then ["listed"] else (.[12] | split(",")) end),
        snippet:       (.[13] // "")
      })
  ' < "$results_file"
else
  # 2>/dev/null + `|| exit 0` keeps output clean when the consumer closes
  # the pipe early (e.g. `| head -n`). Without it, bash's printf emits
  # "write error: Broken pipe" before our PIPE trap fires.
  while IFS=$'\t' read -r ws_ref ws_id ws_name s_ref s_id s_type s_title tty pane_ref pane_id win_ref win_id matched snippet; do
    type_tag="[${s_type}]"
    # Lead with the ref for human orientation; print the surface UUID as the
    # handle to actually pass to commands.
    if [[ "$matched" == "listed" ]]; then
      printf '%s "%s" -> %s %s "%s"\n' "$ws_ref" "$ws_name" "$s_ref" "$type_tag" "$s_title" 2>/dev/null || exit 0
    else
      printf '%s "%s" -> %s %s "%s" [matched: %s]\n' "$ws_ref" "$ws_name" "$s_ref" "$type_tag" "$s_title" "$matched" 2>/dev/null || exit 0
    fi
    printf '    surface_id: %s  workspace_id: %s\n' "$s_id" "$ws_id" 2>/dev/null || exit 0
    if [[ -n "$snippet" ]]; then
      printf '    snippet: %s\n' "$snippet" 2>/dev/null || exit 0
    fi
  done < "$results_file"
fi
