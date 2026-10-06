#!/usr/bin/env bash
# locate.sh — turn live agent sessions into on-screen locators a human can follow.
#
# Usage: locate.sh [--graveyard <file|->] [--herdr]
#
#   --graveyard <file|->  graveyard `candidates --json --no-verdict` output; one
#                         row out per row in. Without it, one row per surface.
#   --herdr               include herdr panes (implied when graveyard has herdr rows)
#
# Prints {legend, windows[], rows[]}. Each row: session_id, transport, title,
# workspace_title, located, join ("surface"|"title"|null), reason, locator,
# group (window › workspace), item (pane, tab).
#
# Read-only by contract (your-cue rule zero): the only verbs issued are
# `cmux tree`, `cmux identify`, and herdr `workspace|tab|pane list`. Every cmux
# locator comes from ONE tree snapshot — refs renumber between reads.
set -u

GY=""
HERDR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --graveyard) GY="${2:-}"; shift 2 ;;
    --herdr)     HERDR=1; shift ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    *)           echo "locate.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "locate.sh: jq is required (brew install jq)" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A read that fails or returns non-JSON becomes `null`, so one unreachable host
# marks its own rows unlocated instead of sinking the whole briefing.
json_or_null() { if [[ -s "$1" ]] && jq -e . "$1" >/dev/null 2>&1; then :; else echo null > "$1"; fi; }

cmux tree --all --json --id-format both > "$TMP/tree.json" 2>/dev/null || : > "$TMP/tree.json"
json_or_null "$TMP/tree.json"
cmux identify --json --id-format both > "$TMP/ident.json" 2>/dev/null || : > "$TMP/ident.json"
json_or_null "$TMP/ident.json"

if [[ -n "$GY" ]]; then
  if [[ "$GY" == "-" ]]; then cat > "$TMP/gy.json"; else cat -- "$GY" > "$TMP/gy.json" || exit 2; fi
  jq -e 'type == "array"' "$TMP/gy.json" >/dev/null 2>&1 || { echo "locate.sh: --graveyard input is not a JSON array" >&2; exit 2; }
  jq -e 'any(.[]; .transport == "herdr")' "$TMP/gy.json" >/dev/null && HERDR=1
else
  echo null > "$TMP/gy.json"
fi

for v in ws tabs panes; do echo null > "$TMP/h-$v.json"; done
if [[ $HERDR -eq 1 ]]; then
  herdr workspace list > "$TMP/h-ws.json"    2>/dev/null || : > "$TMP/h-ws.json"
  herdr tab list       > "$TMP/h-tabs.json"  2>/dev/null || : > "$TMP/h-tabs.json"
  herdr pane list      > "$TMP/h-panes.json" 2>/dev/null || : > "$TMP/h-panes.json"
  for v in ws tabs panes; do json_or_null "$TMP/h-$v.json"; done
fi

jq -n \
  --slurpfile tree  "$TMP/tree.json" \
  --slurpfile ident "$TMP/ident.json" \
  --slurpfile gy    "$TMP/gy.json" \
  --slurpfile hws   "$TMP/h-ws.json" \
  --slurpfile htabs "$TMP/h-tabs.json" \
  --slurpfile hpanes "$TMP/h-panes.json" \
  --argjson want_herdr "$HERDR" '
# Status glyphs (✳ ◑ ⠂ √) change between reads, so matching ignores everything
# before the first letter or digit.
def norm: (. // "") | tostring | sub("^[^\\p{L}\\p{N}]+"; "") | sub("\\s+$"; "");

def labels($d; $n):
  if $n == 2 then (if $d == "horizontal" then ["left","right"] else ["top","bottom"] end)
  elif $n == 3 then (if $d == "horizontal" then ["left","middle","right"] else ["top","middle","bottom"] end)
  else [range(0; $n) | if $d == "horizontal" then "column \(. + 1) of \($n)" else "row \(. + 1) of \($n)" end]
  end;
# A split nested in a split of the same direction reads as one row of columns
# on screen, so flatten it before labelling.
def flat($d): if .pane then [.] elif .direction == $d then [.children[] | flat($d)] | add else [.] end;
def positions($path):
  if .pane then [{ref: .pane.ref, pos: ($path | join(" › "))}]
  else .direction as $d
    | ([.children[] | flat($d)] | add) as $kids
    | labels($d; $kids | length) as $labs
    | [range(0; $kids | length) as $i | $kids[$i] | positions($path + [$labs[$i]])] | add
  end;

($tree[0]) as $t
| ($ident[0].caller.window_id // null) as $me
| ($t.windows // []) as $wins
| ($wins | length) as $nwin
| [ $wins[] | {
      id, index,
      showing: ((.workspaces | map(select(.selected))[0].title) // .workspaces[0].title // "untitled"),
      other: ((.workspaces | map(select(.selected | not))[0].title) // null)
    } ] as $w0
| [ $w0[] | . as $w
    | if $w.id == $me and $me != null then . + {label: "this window"}
      else ("the \"\($w.showing)\" window") as $base
        | ([ $w0[] | select(.id != $me and .showing == $w.showing) ] | length) as $same
        | . + {label: (if $same > 1
                        then $base + (if $w.other then " (with \"\($w.other)\")" else " (window \($w.index + 1))" end)
                        else $base end)}
      end ] as $windows
| ($windows | map({(.id): .label}) | add // {}) as $wlabel

| [ $wins[] as $w | $w.workspaces[] as $ws
    | (if $ws.layout then ($ws.layout | positions([]) | map({(.ref): .pos}) | add) else {} end) as $pos
    | ($ws.panes | length) as $np
    | $ws.panes[] as $p | $p.surfaces[]? as $s
    | ((if $nwin > 1 then $wlabel[$w.id] + " › " else "" end)
       + (if $ws.index < 9 then "⌘\($ws.index + 1)" else "sidebar #\($ws.index + 1)" end)
       + " " + $ws.title) as $group
    | ($p.surface_count // ($p.surfaces | length)) as $tabs
    | ([ (if $np > 1 then "\($pos[$p.ref] // "pane \($p.index + 1) of \($np)") pane" else empty end),
         (if $tabs > 1 then "tab \($s.index_in_pane + 1)/\($tabs)" else empty end) ]
       | if length > 0 then join(", ") else null end) as $item
    | { transport: "cmux", surface_id: $s.id, surface_ref: $s.ref, title: $s.title,
        workspace_title: $ws.title, group: $group, item: $item } ] as $cmux

| ($hws[0].result.workspaces // null) as $hw
| ($hpanes[0].result.panes // null) as $hp
| (($htabs[0].result.tabs // []) | map({(.tab_id): .}) | add // {}) as $htab
| (($hw // []) | map({(.workspace_id): .}) | add // {}) as $hwsix
| [ ($hp // [])[] as $pn
    | ($htab[$pn.tab_id] // {label: $pn.tab_id, number: "?"}) as $tb
    | ($hwsix[$pn.workspace_id] // {label: $pn.workspace_id, number: "?"}) as $wk
    | ([ $hp[] | select(.tab_id == $pn.tab_id) | .pane_id ]) as $siblings
    | ($siblings | index($pn.pane_id)) as $k
    | { transport: "herdr", surface_id: $pn.pane_id, title: $pn.terminal_title_stripped,
        workspace_title: $wk.label, tab_label: $tb.label,
        group: "\($wk.label) (#\($wk.number))",
        item: ("tab \($tb.label) (#\($tb.number))"
               + (if ($siblings | length) > 1 then " › pane \($k + 1) of \($siblings | length)" else "" end)) } ] as $herdr

| def render($title): if .item then "\($title) — \(.group) › \(.item)" else "\($title) — \(.group)" end;
  def found($hit; $how; $title): $hit + {located: true, join: $how, reason: null, title: $title, locator: ($hit | render($title))};
  def missing($r; $why): {transport: ($r.transport // "cmux"), title: $r.tab_title, workspace_title: $r.workspace_title,
                          located: false, join: null, reason: $why, group: null, item: null,
                          locator: "unlocated: \($r.tab_title // "unnamed session \($r.session_id[0:8])")"};

  def title_join($r; $pool):
    ($r.tab_title | norm) as $want
    | if $want == "" then missing($r; "no-match")
      else [ $pool[] | select(.workspace_title == $r.workspace_title) | select(((.title | norm) == $want) or ((.tab_label // null) != null and (.tab_label | norm) == $want)) ] as $c
        | if ($c | length) == 1 then $c[0] as $hit | found($hit; "title"; (if $r.transport == "herdr" then $r.tab_title else $hit.title end))
          elif ($c | length) > 1 then missing($r; "ambiguous-title")
          else missing($r; "no-match") end
      end;

  def cmux_row($r):
    if $t == null then missing($r; "cmux-unreachable")
    elif $r.surface_id then
      ([ $cmux[] | select(.surface_id == $r.surface_id) ][0]) as $hit
      # An unknown surface_id means the surface is gone or the row predates
      # this snapshot; its surface_ref may already name a different tab, so
      # only the title fallback is trusted after that.
      | if $hit then found($hit; "surface"; $hit.title)
        else title_join($r; $cmux) end
    elif $r.surface_ref then
      ([ $cmux[] | select(.surface_ref == $r.surface_ref) ][0]) as $hit
      | if $hit then found($hit; "surface"; $hit.title)
        else title_join($r; $cmux) end
    else title_join($r; $cmux) end;

  # A herdr pane title is the shell, not the agent, so a joined herdr row keeps
  # graveyard'"'"'s tab_title as its name.
  def herdr_row($r):
    if $hp == null or $hw == null then missing($r; "herdr-unreachable")
    else ($r.pane_ref // $r.surface_ref) as $key
      | ([ $herdr[] | select($key != null and .surface_id == $key) ][0]) as $hit
      | if $hit then found($hit; "surface"; ($r.tab_title // $hit.title))
        else title_join($r; $herdr) end
    end;

  (if $gy[0] == null then
     [ $cmux[] | found(.; null; .title) | .join = null | . + {session_id: null} ]
     + (if $want_herdr == 1 then [ $herdr[] | found(.; null; .title) | .join = null | . + {session_id: null} ] else [] end)
   else
     [ $gy[0][] as $r
       | (if ($r.transport // "cmux") == "herdr" then herdr_row($r) else cmux_row($r) end)
       | {session_id: $r.session_id} + . ]
   end) as $rows

| {
    legend: (if $nwin > 1 then
               "Windows: " + ([ ($windows[] | select(.label == "this window") | "this window (showing \"\(.showing)\")"),
                                ($windows[] | select(.label != "this window") | .label) ] | join(" · "))
             else null end),
    windows: [ $windows[] | {window_id: .id, label, showing} ],
    rows: [ $rows[] | {session_id, transport, title, workspace_title, located, join, reason, locator, group, item} ]
  }
'
