#!/usr/bin/env bash
# =============================================================================
# open-side-surface.sh: `new-surface` always carries the container.
#
# `cmux new-surface` scopes its --pane lookup to --workspace, which defaults to
# $CMUX_WORKSPACE_ID — and that scoping applies to a pane UUID exactly as it
# does to a positional `pane:N`. A valid UUID in another workspace comes back
# `not_found: Pane not found`, which hotline's cmux-call-async.sh reads as the
# documented degrade, so every side-by-side dial from an agent-spawned session
# opened a detached tab instead. The shim below models that real scoping: a
# `new-surface` whose workspace is not the subject's is rejected the way cmux
# rejects it, so these cases fail if the opener ever stops pinning the context.
#
# Both directions are fixtured on purpose. The bug was found via `identify`
# returning caller:null (the env surface and workspace disagree, so the tree
# fallback supplies the placement), but the missing flags were in a branch that
# a normal `identify` reaches too. (claude-plugins-qyj1)
#
# A tree whose pane `.id`s are null is fixtured too, because it reaches the
# other `new-surface` branch — the one that targets the positional `pane:N` —
# and because that is the shape where a container UUID packed into the pane
# TSV would shift into the `--pane` slot. Both are asserted by exact argv
# value, not by substring. A tree whose window `.id` is null covers the
# ref fallback for `--window`.
#
# One case covers a different failure in the same code path: cmux echoing a
# `surface:N` it then does not resolve in a tree read. The opener looks that ref
# up to trade it for UUIDs and names, and the `read` consuming that lookup is
# fatal under `set -euo pipefail` when it comes back empty — so the script
# aborted with rc=1, no stdout and no stderr, one line above the fallback
# written for exactly that case, taking hotline's whole cmux transport with it
# (`stage: boot`, `detail: "open-side-surface.sh failed (rc=1): "`). The guard
# is `|| true`; this is what proves it is still there. (claude-plugins-99nu,
# and the ledger's "guard a `read` that consumes a lookup" entry.)
#
# Driven entirely by a shimmed `cmux` on PATH — never touches real cmux.
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"
OPENER="$PLUGIN_DIR/skills/using-cmux-cli/scripts/open-side-surface.sh"

# Workspace X: what the agent-spawned session inherited in its env.
# Workspace Y: where its surface actually lives, per the tree.
WS_X_ID="AAAAAAAA-0000-0000-0000-000000000001"
WS_Y_ID="BBBBBBBB-0000-0000-0000-000000000002"
SURF_CALLER_ID="CCCCCCCC-0000-0000-0000-0000000000C1"
PANE_ADJACENT_ID="DDDDDDDD-0000-0000-0000-0000000000D1"
WIN_ID="EEEEEEEE-0000-0000-0000-0000000000E1"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

command -v jq >/dev/null 2>&1 || {
  echo "side-surface-scope: jq not installed — skipping suite"
  echo "0 passed, 0 failed (skipped: jq missing)"
  exit 0
}

# --- Shim -------------------------------------------------------------------
# Two workspaces in one window. The subject's workspace (Y) holds two panes, so
# the opener takes the new-surface branch and targets the adjacent pane.
make_shim() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/cmux" <<SHIM
#!/usr/bin/env bash
ST="\${CMUX_FAKE_STATE:?}"
WS_X_ID="$WS_X_ID"
WS_Y_ID="$WS_Y_ID"
SURF_CALLER_ID="$SURF_CALLER_ID"
PANE_ADJACENT_ID="$PANE_ADJACENT_ID"
WIN_ID="$WIN_ID"
SHIM
  cat >> "$dir/bin/cmux" <<'SHIM'
case "$1" in --json) shift; [[ "$1 $2" == "--id-format both" ]] || exit 9; shift 2;; esac
case "$1" in
  identify)
    if [[ -n "${CMUX_FAKE_IDENTIFY_EMPTY:-}" ]]; then
      # cmux returns caller:null whenever CMUX_SURFACE_ID and
      # CMUX_WORKSPACE_ID disagree — the agent-spawned-session shape.
      jq -n '{caller: null}'
    else
      jq -n '{caller: {pane_ref:"pane:4", workspace_ref:"workspace:70",
                       window_ref:"window:1", surface_ref:"surface:12"}}'
    fi
    ;;
  tree)
    # Tree reads are COUNTED, because the live bug is a race: the surface is not
    # in the tree yet when the opener looks, and is there moments later. A stub
    # that answers the same way every time cannot exhibit that at all.
    tree_reads=$(( $(cat "$ST/tree_reads" 2>/dev/null || echo 0) + 1 ))
    echo "$tree_reads" > "$ST/tree_reads"
    # The tree call itself failing after the create — the other cause of an
    # unresolved id, and indistinguishable from the first without a diagnostic.
    # Only AFTER the create: the opener's pre-create tree read is what finds the
    # panes, and suppressing that one tests a different branch entirely.
    if [[ -n "${CMUX_FAKE_TREE_EMPTY_AFTER_CREATE:-}" && -s "$ST/create_calls" ]]; then
      exit 0
    fi
    t=$(jq -n \
      --arg wsx "$WS_X_ID" --arg wsy "$WS_Y_ID" --arg win "$WIN_ID" \
      --arg caller "$SURF_CALLER_ID" --arg adj "$PANE_ADJACENT_ID" '
      {windows: [{ref:"window:1", id:$win, index:0, workspaces: [
        {ref:"workspace:9", id:$wsx, index:0, title:"inherited env workspace",
         panes: [{ref:"pane:1", id:"PANE-ELSEWHERE", index:0,
           surfaces: [{ref:"surface:2", id:"SURF-ELSEWHERE", pane_id:"PANE-ELSEWHERE", index:0, title:"zsh"}]}]},
        {ref:"workspace:70", id:$wsy, index:1, title:"real home workspace",
         panes: [
           {ref:"pane:3", id:$adj, index:0, surfaces: [
             {ref:"surface:11", id:"SURF-ADJACENT", pane_id:$adj, index:0, title:"zsh"},
             {ref:"surface:258", id:"SURF-NEW", pane_id:$adj, index:1, title:"zsh"}]},
           {ref:"pane:4", id:"PANE-CALLER", index:1, surfaces: [
             {ref:"surface:12", id:$caller, pane_id:"PANE-CALLER", index:0, title:"agent"}]}]}
      ]}]}')
    # Older cmux (and any tree read without --id-format both) reports `.id` as
    # null. Model each level independently: the opener has a different handle
    # to fall back on for each.
    # tripwire: claude-plugins-7mff — this nulls panes[].id but leaves
    # surfaces[].pane_id set, which cmux cannot produce; a faithful fixture turns
    # cases 1-2 into the rc 4 refusal. Read the bead before making it faithful.
    [[ -n "${CMUX_FAKE_PANE_IDS_NULL:-}" ]] \
      && t=$(printf '%s' "$t" | jq '(.windows[].workspaces[].panes[].id) = null')
    [[ -n "${CMUX_FAKE_WINDOW_ID_NULL:-}" ]] \
      && t=$(printf '%s' "$t" | jq '(.windows[].id) = null')
    # cmux echoes `OK surface:258` and then a tree read does not resolve that
    # ref — observed live, and the shape that aborted the opener outright.
    [[ -n "${CMUX_FAKE_NEW_SURFACE_MISSING:-}" ]] \
      && t=$(printf '%s' "$t" | jq '(.windows[].workspaces[].panes[].surfaces) |=
               map(select(.ref != "surface:258"))')
    # The RACE, as observed live: absent from the first N tree reads taken after
    # the create, present from N+1 on. `--wait-ready --json` reported all four ids
    # null while `cmux tree` moments later resolved the same ref perfectly.
    if [[ -n "${CMUX_FAKE_NEW_SURFACE_AFTER:-}" && -s "$ST/create_calls" ]]; then
      post=$(( tree_reads - $(cat "$ST/tree_reads_at_create" 2>/dev/null || echo 0) ))
      if (( post <= CMUX_FAKE_NEW_SURFACE_AFTER )); then
        t=$(printf '%s' "$t" | jq '(.windows[].workspaces[].panes[].surfaces) |=
               map(select(.ref != "surface:258"))')
      fi
    fi
    printf '%s\n' "$t" ;;
  new-surface|new-pane)
    echo "$*" >> "$ST/create_calls"
    # Where the post-create tree reads start counting from.
    cat "$ST/tree_reads" 2>/dev/null > "$ST/tree_reads_at_create" || echo 0 > "$ST/tree_reads_at_create"
    # Model cmux's real scoping: the --pane lookup happens inside --workspace,
    # defaulting to $CMUX_WORKSPACE_ID. Anything but the subject's own
    # workspace cannot see the pane.
    ws=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == "--workspace" ]] && ws="$a"
      prev="$a"
    done
    [[ -z "$ws" ]] && ws="${CMUX_WORKSPACE_ID:-}"
    if [[ "$ws" != "$WS_Y_ID" && "$ws" != "workspace:70" ]]; then
      echo "Error: not_found: Pane not found" >&2
      exit 1
    fi
    jq -n --arg ws "$WS_Y_ID" --arg pane "$PANE_ADJACENT_ID" '{surface_id:"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",surface_ref:"surface:258",pane_id:$pane,pane_ref:"pane:3",workspace_id:$ws,workspace_ref:"workspace:70"}' ;;
  rename-tab) echo "OK" ;;
  focus-pane|send|read-screen) exit 0 ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$dir/bin/cmux"
}

# The value cmux received for a flag, read back out of the recorded argv.
arg_after() {
  awk -v f="$1" '{for (i = 1; i <= NF; i++) if ($i == f) { print $(i+1); exit }}' \
    "$2" 2>/dev/null
}

want() {
  local label="$1" got="$2" expect="$3"
  if [[ "$got" == "$expect" ]]; then pass "$label"; else fail "$label" "got=[$got] want=[$expect]"; fi
}

# Assert the recorded create call carries the intended pane handle and the
# subject's real container. Exact values, because the failure mode being
# guarded is the right flag with the wrong value in it.
assert_pinned() {
  local label="$1" calls_file="$2" want_pane="$3" want_win="$4"
  local calls got_pane
  calls=$(cat "$calls_file" 2>/dev/null || echo NONE)
  got_pane=$(arg_after --pane "$calls_file")
  want "$label: targets the adjacent pane as $want_pane" "$got_pane" "$want_pane"
  want "$label: pins --workspace to the pane's real workspace, not the inherited one" \
       "$(arg_after --workspace "$calls_file")" "$WS_Y_ID"
  want "$label: pins --window alongside it" "$(arg_after --window "$calls_file")" "$want_win"
  # A container UUID in the --pane slot is `not_found: Pane not found` all over
  # again, and it is what a collapsed multi-column TSV read produces.
  if [[ "$got_pane" != "$WS_Y_ID" && "$got_pane" != "$WS_X_ID" && "$got_pane" != "$WIN_ID" ]]; then
    pass "$label: --pane never receives a container UUID"
  else
    fail "$label: --pane never receives a container UUID" "calls=$calls"
  fi
  if ! grep -q -- "--workspace $WS_X_ID" <<<"$calls"; then
    pass "$label: never hands cmux the inherited CMUX_WORKSPACE_ID"
  else
    fail "$label: never hands cmux the inherited CMUX_WORKSPACE_ID" "calls=$calls"
  fi
}

echo "open-side-surface.sh new-surface container scoping:"

# --- Case 1: identify returns caller:null; the tree supplies the placement ---
# The live shape from claude-plugins-qyj1: the env names workspace X, the
# surface actually lives in workspace Y.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-a-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" CMUX_FAKE_IDENTIFY_EMPTY=1 \
      CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
      bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "surface:258" ]]; then
  pass "identify caller:null — opens side-by-side instead of failing not_found"
else
  fail "identify caller:null — opens side-by-side instead of failing not_found" \
       "rc=$rc out=$out err=$(cat "$tmp/err.txt")"
fi
assert_pinned "identify caller:null" "$tmp/create_calls" "$PANE_ADJACENT_ID" "$WIN_ID"

# --- Case 2: identify succeeds normally — the flags are still there ---
# Same branch, reached the ordinary way. The env still names workspace X, so a
# bare --pane would fail here too.
tmp2=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-b-XXXXXX"); make_shim "$tmp2"
out2=$(PATH="$tmp2/bin:$PATH" CMUX_FAKE_STATE="$tmp2" \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp2/err.txt")
rc2=$?
if [[ $rc2 -eq 0 && "$(jq -r '.surface_ref' <<<"$out2" 2>/dev/null)" == "surface:258" ]]; then
  pass "identify succeeds — opens side-by-side"
else
  fail "identify succeeds — opens side-by-side" \
       "rc=$rc2 out=$out2 err=$(cat "$tmp2/err.txt")"
fi
assert_pinned "identify succeeds" "$tmp2/create_calls" "$PANE_ADJACENT_ID" "$WIN_ID"

# --- Case 3: a missing pane UUID must not fall back to a positional target ---
tmp3=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-c-XXXXXX"); make_shim "$tmp3"
out3=$(PATH="$tmp3/bin:$PATH" CMUX_FAKE_STATE="$tmp3" CMUX_FAKE_PANE_IDS_NULL=1 \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp3/err.txt")
rc3=$?
if [[ $rc3 -eq 2 && ! -s "$tmp3/create_calls" ]]; then
  pass "pane .id null — refuses positional target"
else
  fail "pane .id null — refuses positional target" "rc=$rc3"
fi

# --- Case 4: a missing window UUID must not fall back to a positional target ---
tmp4=$(mktemp -d "${TMPDIR:-/tmp}/cmux-scope-d-XXXXXX"); make_shim "$tmp4"
out4=$(PATH="$tmp4/bin:$PATH" CMUX_FAKE_STATE="$tmp4" CMUX_FAKE_WINDOW_ID_NULL=1 \
       CMUX_SURFACE_ID="$SURF_CALLER_ID" CMUX_WORKSPACE_ID="$WS_X_ID" \
       bash "$OPENER" --caller --title "scoped side surface" --json 2>"$tmp4/err.txt")
rc4=$?
if [[ $rc4 -eq 2 && ! -s "$tmp4/create_calls" ]]; then
  pass "window .id null — refuses positional container"
else
  fail "window .id null — refuses positional container" "rc=$rc4"
fi

echo
echo "side-surface-scope: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
