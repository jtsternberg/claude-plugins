#!/usr/bin/env bash
# =============================================================================
# Regression guard: a surface an agent opens must be *findable by a human*.
#
# The failure this pins: an agent opened a test surface whose title and
# workspace were both the generic word "workspace", then reported only
# "surface:258". The ref was correct and completely useless — cmux never shows
# refs in its UI, and they renumber as tabs open and close.
#
# Two halves, matching the two obligations:
#   1. open-side-surface.sh --title actually names the tab (cmux rename-tab) and
#      hands back the human-readable names to report (surface_title,
#      workspace_name); omitting --title says so loudly on stderr instead of
#      silently returning an unfindable surface.
#   2. SKILL.md still carries the explicit requirement. Prose, so grep-level —
#      but the requirement was absent once already, and this is what notices if
#      it gets edited back out.
#
# Driven entirely by a shimmed `cmux` on PATH — never touches real cmux, so it
# runs on Linux CI too.
# =============================================================================
set -u

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/using-cmux-cli"
OPENER="$SKILL_DIR/scripts/open-side-surface.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

command -v jq >/dev/null 2>&1 || {
  echo "surface-naming: jq not installed — skipping suite"
  echo "0 passed, 0 failed (skipped: jq missing)"
  exit 0
}

# --- Shared cmux shim -------------------------------------------------------
# Models one window / one workspace ("plugin surface naming") / one pane, so the
# opener takes the new-pane branch. Records rename-tab calls; reflects an applied
# rename back into the tree so a follow-up read would see it.
make_shim() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/cmux" <<'SHIM'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
title_file="$ST/current_title"
[[ -f "$title_file" ]] || printf 'zsh' > "$title_file"
TITLE=$(cat "$title_file")

emit_tree() {
  jq -n --arg t "$TITLE" '{
    windows: [{
      ref: "window:1", id: "WIN-UUID", index: 0,
      workspaces: [{
        ref: "workspace:7", id: "WS-UUID", index: 0, title: "plugin surface naming",
        panes: [{
          ref: "pane:3", id: "PANE-UUID", index: 0,
          surfaces: [
            { ref: "surface:11", id: "SURF-OLD", pane_id: "PANE-UUID", index: 0, title: "agent" },
            { ref: "surface:258", id: "SURF-NEW", pane_id: "PANE-UUID", index: 1, title: $t }
          ]
        }]
      }]
    }]
  }'
}

case "$1" in
  identify)
    if [[ -n "${CMUX_FAKE_IDENTIFY_EMPTY:-}" ]]; then
      jq -n '{caller: null}'
    else
      jq -n '{caller: {pane_ref:"pane:3", workspace_ref:"workspace:7",
                       window_ref:"window:1", surface_ref:"surface:11"}}'
    fi
    ;;
  tree) emit_tree ;;
  new-pane|new-surface)
    echo "$*" >> "$ST/create_calls"
    echo "OK surface:258 pane:3 workspace:7"
    ;;
  rename-tab)
    echo "$*" >> "$ST/rename_calls"
    if [[ -n "${CMUX_FAKE_RENAME_FAILS:-}" ]]; then
      echo "Error: not_found: Tab not found" >&2; exit 1
    fi
    # Trailing positional title, after the `--` separator the opener passes.
    new=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--" ]] && { shift; new="$*"; break; }
      shift
    done
    [[ -n "$new" ]] && printf '%s' "$new" > "$title_file"
    echo "OK"
    ;;
  focus-pane|send|read-screen) exit 0 ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$dir/bin/cmux"
}

echo "open-side-surface.sh --title:"

# Case 1 — --title reaches `cmux rename-tab`, targeting the NEW surface's UUID
# (not the caller's, and not the positional ref).
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-naming-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
      bash "$OPENER" --title "dev server :3000" --json 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "exits 0 with --title"
else
  fail "exits 0 with --title" "rc=$rc err=$(cat "$tmp/err.txt")"
fi
if grep -q 'rename-tab .*--tab SURF-NEW' "$tmp/rename_calls" 2>/dev/null \
   && grep -q 'dev server :3000' "$tmp/rename_calls" 2>/dev/null; then
  pass "--title applies the name via rename-tab on the new surface's UUID"
else
  fail "--title applies the name via rename-tab on the new surface's UUID" \
       "calls=$(cat "$tmp/rename_calls" 2>/dev/null || echo NONE)"
fi
if [[ "$(jq -r '.surface_title' <<<"$out")" == "dev server :3000" ]]; then
  pass "JSON reports surface_title (the thing you tell the user)"
else
  fail "JSON reports surface_title" "got=$(jq -c '.surface_title' <<<"$out" 2>/dev/null)"
fi
if [[ "$(jq -r '.workspace_name' <<<"$out")" == "plugin surface naming" ]]; then
  pass "JSON reports workspace_name (so the user knows which workspace to find)"
else
  fail "JSON reports workspace_name" "got=$(jq -c '.workspace_name' <<<"$out" 2>/dev/null)"
fi
if [[ "$(jq -r '.title_status' <<<"$out")" == "applied" ]]; then
  pass "title_status=applied on success"
else
  fail "title_status=applied on success" "got=$(jq -c '.title_status' <<<"$out" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case 2 — a non-tty Bash-tool shell can get caller:null from identify. The
# stable CMUX_SURFACE_ID still names the caller, so resolve its live placement
# from tree instead of failing (which made Hotline silently open a detached
# workspace and lose reusable-surface bookkeeping).
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-naming-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
      CMUX_FAKE_IDENTIFY_EMPTY=1 CMUX_SURFACE_ID="SURF-OLD" \
      bash "$OPENER" --json 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(jq -r '.surface_ref' <<<"$out")" == "surface:258" ]]; then
  pass "caller:null falls back through CMUX_SURFACE_ID tree lookup"
else
  fail "caller:null falls back through CMUX_SURFACE_ID tree lookup" \
       "rc=$rc out=$out err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# The fallback is best-effort: a stale UUID must still reach the normal,
# diagnostic context error rather than exiting early under `set -e`.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-naming-XXXXXX"); make_shim "$tmp"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  CMUX_FAKE_IDENTIFY_EMPTY=1 CMUX_SURFACE_ID="SURF-NOT-IN-TREE" \
  bash "$OPENER" --json >"$tmp/out.txt" 2>"$tmp/err.txt"
rc=$?
if [[ $rc -eq 2 ]] && grep -q 'could not resolve caller' "$tmp/err.txt"; then
  pass "stale CMUX_SURFACE_ID fails with the normal context diagnostic"
else
  fail "stale CMUX_SURFACE_ID fails with the normal context diagnostic" \
       "rc=$rc err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

# Case 3 — no --title: the surface is still created (hotline and other callers
# rely on that), but stderr says the tab is unfindable and how to name it.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-naming-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
      bash "$OPENER" --json 2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(jq -r '.surface_ref' <<<"$out")" == "surface:258" ]]; then
  pass "omitting --title still creates the surface (backward compatible)"
else
  fail "omitting --title still creates the surface" "rc=$rc out=$out"
fi
if [[ ! -f "$tmp/rename_calls" ]]; then
  pass "no rename-tab call when no --title given"
else
  fail "no rename-tab call when no --title given" "calls=$(cat "$tmp/rename_calls")"
fi
if grep -q 'rename-tab' "$tmp/err.txt" 2>/dev/null; then
  pass "stderr hints how to name an untitled surface"
else
  fail "stderr hints how to name an untitled surface" "err=$(cat "$tmp/err.txt")"
fi
if [[ "$(jq -r '.title_status' <<<"$out")" == "unset" ]]; then
  pass "title_status=unset when no --title given"
else
  fail "title_status=unset when no --title given" "got=$(jq -c '.title_status' <<<"$out" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case 4 — rename failure is surfaced, not swallowed. A silently-failed rename is
# how you end up reporting a generic title in good faith.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-naming-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" CMUX_FAKE_RENAME_FAILS=1 \
      bash "$OPENER" --title "tail nginx logs" --json 2>"$tmp/err.txt")
if [[ "$(jq -r '.title_status' <<<"$out")" == "failed" ]]; then
  pass "title_status=failed when rename-tab errors"
else
  fail "title_status=failed when rename-tab errors" "got=$(jq -c '.title_status' <<<"$out" 2>/dev/null)"
fi
if grep -q "rename-tab' failed" "$tmp/err.txt" 2>/dev/null; then
  pass "rename failure is reported on stderr with a retry command"
else
  fail "rename failure is reported on stderr" "err=$(cat "$tmp/err.txt")"
fi
if [[ "$(jq -r '.surface_title' <<<"$out")" == "zsh" ]]; then
  pass "surface_title falls back to the real (generic) title, not the intended one"
else
  fail "surface_title falls back to the real title" "got=$(jq -c '.surface_title' <<<"$out" 2>/dev/null)"
fi
rm -rf "$tmp"

# Case 5 — text (non-JSON) output carries the names too, since that's the mode a
# human reads.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-naming-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
      bash "$OPENER" --title "pytest watch" 2>/dev/null)
if grep -q '^title: pytest watch$' <<<"$out" \
   && grep -q '^workspace: plugin surface naming (workspace:7)$' <<<"$out"; then
  pass "text output prints title: and workspace: lines"
else
  fail "text output prints title: and workspace: lines" "out=$out"
fi
rm -rf "$tmp"

echo "SKILL.md naming/reporting requirement:"

# Case 6 — the instruction itself. It was absent once; these assert the two
# obligations and the concrete failure are still stated.
if grep -q '### Name it, then report it by name (required)' "$SKILL_MD"; then
  pass "SKILL.md has the required naming/reporting section"
else
  fail "SKILL.md has the required naming/reporting section" \
       "heading missing from $SKILL_MD"
fi
if grep -q 'Give it a meaningful human-visible title' "$SKILL_MD"; then
  pass "obligation 1 stated: name the surface"
else
  fail "obligation 1 stated: name the surface"
fi
if grep -q 'Report the title plus its workspace — never a bare positional ref' "$SKILL_MD"; then
  pass "obligation 2 stated: report title + workspace, not a ref"
else
  fail "obligation 2 stated: report title + workspace, not a ref"
fi
if grep -q 'surface:258' "$SKILL_MD"; then
  pass "the concrete failure (bare surface:258 report) is documented"
else
  fail "the concrete failure (bare surface:258 report) is documented"
fi
if grep -q -- '`--title "<purpose>"`\|--title "dev server :3000"' "$SKILL_MD"; then
  pass "the default recipe passes --title"
else
  fail "the default recipe passes --title"
fi

echo
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf 'failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
