#!/usr/bin/env bash
# =============================================================================
# Behavior tests for your-cue's scripts/locate.sh.
#
# `cmux` and `herdr` are PATH stubs that serve fixtures and log every argv, so
# the suite never touches a live host — and the log is what pins rule zero:
# the script may only ever issue the read verbs asserted at the bottom.
#
# The fixture tree carries the cases the live 2026-10-06 run hit: a nested
# same-direction split (left/middle/right), a horizontal-in-vertical split,
# colliding tab titles ("lg"), status glyphs that change between reads, ten
# workspaces in one window (⌘n only covers 1–9), and two windows showing a
# workspace with the same title.
# =============================================================================
set -u

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOCATE="$ROOT/plugins/maestro/skills/your-cue/scripts/locate.sh"

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [[ -n "${2:-}" ]] && echo "#   $2"; }

# eq <description> <expected> <actual>
eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  echo "0 passed, 0 failed"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fx"
LOG="$TMP/calls.log"

# --- stubs -------------------------------------------------------------------

cat > "$TMP/bin/cmux" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >> "$STUB_LOG"
case "$1" in
  tree)     cat "$FX_TREE" ;;
  identify) [[ -n "${FX_IDENTIFY:-}" ]] && cat "$FX_IDENTIFY" || { echo "Error: not in cmux" >&2; exit 1; } ;;
  *)        echo "stub: unexpected cmux verb $1" >&2; exit 9 ;;
esac
EOF
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >> "$STUB_LOG"
[[ -n "${FX_HERDR_DOWN:-}" ]] && { echo "Error: herdr server not running" >&2; exit 1; }
case "$1 $2" in
  "workspace list") cat "$FX_DIR/herdr-ws.json" ;;
  "tab list")       cat "$FX_DIR/herdr-tabs.json" ;;
  "pane list")      cat "$FX_DIR/herdr-panes.json" ;;
  *)                echo "stub: unexpected herdr verb $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP/bin/cmux" "$TMP/bin/herdr"

# --- fixtures ----------------------------------------------------------------

# surface <id> <title> [index_in_pane]
s() { printf '{"id":"%s","ref":"surface:%s","title":"%s","index_in_pane":%s,"type":"terminal"}' "$1" "$1" "$2" "${3:-0}"; }
# pane <id> <index> <surfaces-json-array>
p() { printf '{"id":"%s","ref":"pane:%s","index":%s,"surfaces":%s,"surface_count":%s}' "$1" "$1" "$2" "$3" "$(jq length <<<"$3")"; }
leaf() { printf '{"pane":{"ref":"pane:%s"}}' "$1"; }
split() { printf '{"direction":"%s","split":0.5,"children":[%s,%s]}' "$1" "$2" "$3"; }
# workspace <id> <index> <title> <selected> <layout> <panes-json-array>
w() { printf '{"id":"%s","ref":"workspace:%s","index":%s,"title":"%s","selected":%s,"layout":%s,"panes":%s}' "$1" "$1" "$2" "$3" "$4" "$5" "$6"; }

# Window A: the caller's window. ws0 "your cue" (shown), ws1 "announce cli"
# (two panes, colliding "lg" tabs), ws2..ws8 fillers, ws9 "tenth ws".
A_WS="$(w WS-CUE 0 'your cue' true "$(leaf P-CUE)" "[$(p P-CUE 0 "[$(s S-CALLER '◑ caller tab')]")]")"
A_WS="$A_WS,$(w WS-ANN 1 'announce cli' false "$(split horizontal "$(leaf P-ANN1)" "$(leaf P-ANN2)")" \
  "[$(p P-ANN1 0 "[$(s S-ORIG orig 0),$(s S-DRAFT '✳ hotline: draft cli login issue' 1),$(s S-LG1 lg 2)]"),$(p P-ANN2 1 "[$(s S-LG2 lg 0),$(s S-CC '✳ Claude Code' 1)]")]")"
for i in 2 3 4 5 6 7 8; do
  A_WS="$A_WS,$(w "WS-F$i" "$i" "filler $i" false "$(leaf "P-F$i")" "[$(p "P-F$i" 0 "[$(s "S-F$i" "filler tab $i")]")]")"
done
A_WS="$A_WS,$(w WS-TEN 9 'tenth ws' false "$(leaf P-TEN)" "[$(p P-TEN 0 "[$(s S-TEN 'deep tab')]")]")"

# Window B: ws0 "agentic-dev" (shown): horizontal[P-L, horizontal[P-M, P-R]]
# → left/middle/right. ws1 "stack": horizontal[P-S1, vertical[P-S2, P-S3]].
B_WS="$(w WS-AD 0 'agentic-dev' true "$(split horizontal "$(leaf P-L)" "$(split horizontal "$(leaf P-M)" "$(leaf P-R)")")" \
  "[$(p P-L 0 "[$(s S-L1 '√ ✳ PR 2680 merge readiness' 0),$(s S-L2 'PR 2678 merge readiness' 1),$(s S-FABLE 'fable overseer watch PRs' 2)]"),$(p P-M 1 "[$(s S-MID 'pr-merge-review 767')]"),$(p P-R 2 "[$(s S-RIGHT 'agent overseer')]")]")"
B_WS="$B_WS,$(w WS-ST 1 'stack' false "$(split horizontal "$(leaf P-S1)" "$(split vertical "$(leaf P-S2)" "$(leaf P-S3)")")" \
  "[$(p P-S1 0 "[$(s S-S1 'stack left')]"),$(p P-S2 1 "[$(s S-S2 'stack top')]"),$(p P-S3 2 "[$(s S-S3 'stack bottom')]")]")"

# Window C: also shows a workspace titled "agentic-dev".
C_WS="$(w WS-AD2 0 'agentic-dev' true "$(leaf P-C)" "[$(p P-C 0 "[$(s S-C 'other agentic tab')]")]")"
C_WS="$C_WS,$(w WS-THEME 1 'cmux theme' false "$(leaf P-TH)" "[$(p P-TH 0 "[$(s S-TH 'theme tab')]")]")"

cat > "$TMP/fx/tree.json" <<EOF
{"windows":[
 {"id":"W-A","ref":"window:1","index":0,"workspaces":[$A_WS]},
 {"id":"W-B","ref":"window:2","index":1,"workspaces":[$B_WS]},
 {"id":"W-C","ref":"window:3","index":2,"workspaces":[$C_WS]}
]}
EOF
cat > "$TMP/fx/single.json" <<EOF
{"windows":[{"id":"W-A","ref":"window:1","index":0,"workspaces":[$A_WS]}]}
EOF
cat > "$TMP/fx/identify.json" <<'EOF'
{"caller":{"window_id":"W-A","window_ref":"window:1","surface_id":"S-CALLER","surface_ref":"surface:S-CALLER"},"focused":null}
EOF

cat > "$TMP/fx/herdr-ws.json" <<'EOF'
{"result":{"workspaces":[{"workspace_id":"w28","label":"agentic-run-boss","number":1},{"workspace_id":"w29","label":"agentic-run-fixes","number":2}]}}
EOF
cat > "$TMP/fx/herdr-tabs.json" <<'EOF'
{"result":{"tabs":[{"tab_id":"w28:t1","workspace_id":"w28","label":"boss","number":1,"pane_count":2},{"tab_id":"w29:t1","workspace_id":"w29","label":"1","number":1,"pane_count":1},{"tab_id":"w29:tB","workspace_id":"w29","label":"d82c0e-deep-lift","number":11,"pane_count":1}]}}
EOF
cat > "$TMP/fx/herdr-panes.json" <<'EOF'
{"result":{"panes":[
 {"pane_id":"w28:p1","tab_id":"w28:t1","workspace_id":"w28","terminal_title_stripped":"boss agent"},
 {"pane_id":"w28:p2","tab_id":"w28:t1","workspace_id":"w28","terminal_title_stripped":"boss shell"},
 {"pane_id":"w29:p1","tab_id":"w29:t1","workspace_id":"w29","terminal_title_stripped":"zsh"},
 {"pane_id":"w29:pB","tab_id":"w29:tB","workspace_id":"w29","terminal_title_stripped":"fixer"}
]}}
EOF

# Graveyard rows. New-format rows carry the exact refs; old-format rows carry
# titles only (the shape before graveyard emitted the refs).
cat > "$TMP/fx/gy.json" <<'EOF'
[
 {"session_id":"sid-exact","transport":"cmux","workspace_title":"announce cli","tab_title":"⠂ hotline: draft cli login issue","cwd":"/r","surface_id":"S-DRAFT","surface_ref":"surface:999","pane_ref":null,"workspace_ref":null,"window_ref":null},
 {"session_id":"sid-title","transport":"cmux","workspace_title":"agentic-dev","tab_title":"✳ fable overseer watch PRs","cwd":"/r"},
 {"session_id":"sid-dupe","transport":"cmux","workspace_title":"announce cli","tab_title":"lg","cwd":"/r"},
 {"session_id":"sid-stale","transport":"cmux","workspace_title":"stack","tab_title":"stack top","cwd":"/r","surface_id":"S-GONE","surface_ref":"surface:S-S1","pane_ref":null,"workspace_ref":null,"window_ref":null},
 {"session_id":"sid-cwd","transport":"cmux","workspace_title":"announce cli","tab_title":"no such tab","cwd":"/r"},
 {"session_id":"sid-deep","transport":"cmux","workspace_title":"tenth ws","tab_title":"deep tab","cwd":"/r"},
 {"session_id":"sid-hexact","transport":"herdr","workspace_title":"agentic-run-fixes","tab_title":"fixer agent","cwd":"/r","surface_id":"w29:pB","surface_ref":"w29:pB","pane_ref":"w29:pB","workspace_ref":"w29","tab_ref":"w29:tB","window_ref":null},
 {"session_id":"sid-htitle","transport":"herdr","workspace_title":"agentic-run-boss","tab_title":"boss shell","cwd":"/r"}
]
EOF

# --- runner ------------------------------------------------------------------

# run <tree-fixture> [identify-fixture|""] [args...] → stdout to $TMP/out.json
run() {
  local tree="$1" ident="$2"; shift 2
  : > "$LOG"
  PATH="$TMP/bin:$PATH" STUB_LOG="$LOG" FX_DIR="$TMP/fx" FX_TREE="$tree" FX_IDENTIFY="$ident" \
    bash "$LOCATE" "$@" > "$TMP/out.json" 2> "$TMP/err.txt"
  RC=$?
}
# row <session_id> <jq-field-expr>
row() { jq -r --arg s "$1" ".rows[] | select(.session_id==\$s) | $2" "$TMP/out.json"; }

if [[ ! -f "$LOCATE" ]]; then
  fail "locate.sh exists at skills/your-cue/scripts/locate.sh"
  echo "${PASS} passed, ${FAIL} failed"
  exit 1
fi

# --- graveyard join, three windows -------------------------------------------

run "$TMP/fx/tree.json" "$TMP/fx/identify.json" --graveyard "$TMP/fx/gy.json"
eq "exits 0" 0 "$RC"
eq "emits valid JSON" ok "$(jq -e . "$TMP/out.json" >/dev/null 2>&1 && echo ok)"

eq "exact surface_id join wins over a stale title glyph" surface "$(row sid-exact .join)"
eq "exact join locator: this window, ⌘2, left pane, tab 2/3" \
  '✳ hotline: draft cli login issue — this window › ⌘2 announce cli › left pane, tab 2/3' "$(row sid-exact .locator)"
eq "locator shows the title as cmux renders it now, not graveyard's copy" \
  '✳ hotline: draft cli login issue' "$(row sid-exact .title)"

eq "id-less row falls back to a unique title match, ignoring glyphs" title "$(row sid-title .join)"
eq "nested same-direction split flattens to left/middle/right; window named by what it shows" \
  'fable overseer watch PRs — the "agentic-dev" window (with "stack") › ⌘1 agentic-dev › left pane, tab 3/3' "$(row sid-title .locator)"

eq "a title shared by two tabs is unlocated, never guessed" false "$(row sid-dupe .located)"
eq "ambiguous row says why" ambiguous-title "$(row sid-dupe .reason)"
eq "unlocated row renders as unlocated: <title>" 'unlocated: lg' "$(row sid-dupe .locator)"

eq "unknown surface_id falls back to title rather than trusting a reassigned surface_ref" title "$(row sid-stale .join)"
eq "horizontal-in-vertical split composes the path" \
  'stack top — the "agentic-dev" window (with "stack") › ⌘2 stack › right › top pane' "$(row sid-stale .locator)"

eq "a row matching only by cwd stays unlocated" false "$(row sid-cwd .located)"
eq "no-match row says why" no-match "$(row sid-cwd .reason)"

eq "workspace past 9 gets sidebar #n, single pane and tab omitted" \
  'deep tab — this window › sidebar #10 tenth ws' "$(row sid-deep .locator)"

eq "herdr exact pane_ref join" surface "$(row sid-hexact .join)"
eq "herdr locator: workspace (#n) › tab (#n), lone pane omitted" \
  'fixer agent — agentic-run-fixes (#2) › tab d82c0e-deep-lift (#11)' "$(row sid-hexact .locator)"
eq "herdr title fallback with pane k of m" \
  'boss shell — agentic-run-boss (#1) › tab boss (#1) › pane 2 of 2' "$(row sid-htitle .locator)"

eq "grouping key carries window and workspace" 'this window › ⌘2 announce cli' "$(row sid-exact .group)"
eq "grouping item carries pane and tab" 'left pane, tab 2/3' "$(row sid-exact .item)"

eq "legend names every window; this window first" \
  'Windows: this window (showing "your cue") · the "agentic-dev" window (with "stack") · the "agentic-dev" window (with "cmux theme")' \
  "$(jq -r .legend "$TMP/out.json")"

# --- rule zero: one snapshot, read verbs only --------------------------------

eq "one tree snapshot per run" 1 "$(grep -c '^cmux tree' "$LOG")"
eq "tree read carries UUIDs" 1 "$(grep -c '^cmux tree --all --json --id-format both$' "$LOG")"
eq "only read verbs are issued" 0 \
  "$(grep -vcE '^(cmux tree --all --json --id-format both|cmux identify --json --id-format both|herdr (workspace|tab|pane) list)$' "$LOG")"

# --- no graveyard: every surface ---------------------------------------------

run "$TMP/fx/tree.json" "$TMP/fx/identify.json"
eq "without --graveyard every cmux surface is a row" 24 "$(jq '.rows | length' "$TMP/out.json")"
eq "without --herdr no herdr call is made" 0 "$(grep -c '^herdr' "$LOG")"

# --- single window: no window segment, no legend -----------------------------

run "$TMP/fx/single.json" "$TMP/fx/identify.json" --graveyard "$TMP/fx/gy.json"
eq "single window drops the window segment" \
  '✳ hotline: draft cli login issue — ⌘2 announce cli › left pane, tab 2/3' "$(row sid-exact .locator)"
eq "single window has no legend" null "$(jq -r .legend "$TMP/out.json")"

# --- outside cmux: no "this window" ------------------------------------------

run "$TMP/fx/tree.json" "" --graveyard "$TMP/fx/gy.json"
eq "identify failure is not fatal" 0 "$RC"
eq "without a caller, every window is named by what it shows" \
  '✳ hotline: draft cli login issue — the "your cue" window › ⌘2 announce cli › left pane, tab 2/3' "$(row sid-exact .locator)"

# --- herdr down: its rows are unlocated, cmux rows still resolve -------------

FX_HERDR_DOWN=1 run "$TMP/fx/tree.json" "$TMP/fx/identify.json" --graveyard "$TMP/fx/gy.json"
eq "herdr unreachable is not fatal" 0 "$RC"
eq "herdr rows say the host was unreachable" herdr-unreachable "$(row sid-hexact .reason)"
eq "cmux rows still resolve with herdr down" surface "$(row sid-exact .join)"

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
