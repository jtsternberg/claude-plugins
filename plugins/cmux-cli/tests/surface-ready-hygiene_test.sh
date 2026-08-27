#!/usr/bin/env bash
# =============================================================================
# open-side-surface.sh --wait-ready: PTY attachment WITHOUT focus theft, with a
# clean input line and a scroll-immune read.
#
# Three rules, all of them paid for in live incidents on 2026-08-26:
#
#   1. NOTHING FOCUSES. `cmux send` attaches a surface's PTY lazily on first
#      send, so the probe below is the attachment step. `cmux focus-pane` also
#      attaches it, eagerly, but it does so by moving the USER'S FOCUS into a
#      brand-new pane — and whatever they are typing at that instant then goes to
#      the callee's shell. Measured saving over the probe send: ~0.1s.
#
#   2. THE INPUT LINE IS CLEARED FIRST. It is shared with the user. A probe
#      concatenated onto three stray keystrokes renders `rkeecho <marker>`, whose
#      error line carries the marker TWICE and so satisfies the >=2-hit readiness
#      test while proving nothing about the shell executing input. Ctrl-U (raw
#      0x15) through the TEXT path — `send-key ctrl+u` does not reach the program.
#
#   3. EVERY READ IS SCROLL-IMMUNE. Bare `read-screen` returns whatever the pane
#      is currently showing, so a user scrolled up freezes the capture and the
#      probe loop spins to its ceiling against a surface that was ready seconds
#      ago. `--scrollback --lines N` returns the live tail regardless of scroll
#      (verified on cmux 0.64.22 against a pane scrolled to ~line 225).
#
# Plus the handle rule the same day taught three times over: `cmux send --surface
# ""` does not fail, it delivers to the FOCUSED surface. An empty handle is never
# a default.
#
# Driven entirely by a shimmed `cmux` on PATH — never touches real cmux.
# (claude-plugins-r465.4, -r465.5, -r465.7)
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/using-cmux-cli"
OPENER="$SKILL_DIR/scripts/open-side-surface.sh"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

command -v jq >/dev/null 2>&1 || {
  echo "surface-ready-hygiene: jq not installed — skipping suite"
  echo "0 passed, 0 failed (skipped: jq missing)"
  exit 0
}

# --- Shim -------------------------------------------------------------------
# One window / one workspace / one pane, so the opener takes the new-pane branch.
# `send` round-trips the readiness marker (the typed line plus the shell's output
# line) so --wait-ready succeeds; every call is logged by verb.
make_shim() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/cmux" <<'SHIM'
#!/usr/bin/env bash
ST="${CMUX_FAKE_STATE:?}"
case "$1" in
  identify)
    jq -n '{caller: {pane_ref:"pane:3", workspace_ref:"workspace:7",
                     window_ref:"window:1", surface_ref:"surface:11"}}' ;;
  tree)
    jq -n '{windows: [{ref:"window:1", id:"WIN-UUID", index:0,
      workspaces: [{ref:"workspace:7", id:"WS-UUID", index:0, title:"ready hygiene",
        panes: [{ref:"pane:3", id:"PANE-UUID", index:0,
          surfaces: [{ref:"surface:11", id:"SURF-OLD", pane_id:"PANE-UUID", index:0, title:"agent"},
                     {ref:"surface:258", id:"SURF-NEW", pane_id:"PANE-UUID", index:1, title:"zsh"}]}]}]}]}' ;;
  new-pane|new-surface)
    echo "$*" >> "$ST/create_calls"; echo "OK surface:258 pane:3 workspace:7" ;;
  rename-tab) echo "OK" ;;
  focus-pane) echo "$*" >> "$ST/focus_calls"; exit 0 ;;
  send)
    printf '%q ' "$@" >> "$ST/send_calls"; printf '\n' >> "$ST/send_calls"
    m=$(printf '%s' "$*" | grep -oE '__CMUX_PTYREADY_[0-9]+__' | head -1)
    if [[ -n "$m" && -z "${CMUX_FAKE_NEVER_READY:-}" ]]; then
      { echo "$m"; echo "$m"; } >> "$ST/screen.txt"
    fi
    exit 0 ;;
  read-screen)
    echo "$*" >> "$ST/read_calls"; cat "$ST/screen.txt" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$dir/bin/cmux"
}

echo "open-side-surface.sh --wait-ready:"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-ready-XXXXXX"); make_shim "$tmp"
out=$(PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" \
  bash "$OPENER" --caller --wait-ready --wait-ready-timeout 5 --title "probe target" --json \
  2>"$tmp/err.txt")
rc=$?
if [[ $rc -eq 0 && "$(jq -r '.ready' <<<"$out" 2>/dev/null)" == "ready" ]]; then
  pass "--wait-ready reports ready once the probe echoes back twice"
else
  fail "--wait-ready reports ready once the probe echoes back twice" \
       "rc=$rc out=$out err=$(cat "$tmp/err.txt")"
fi

if [[ ! -s "$tmp/focus_calls" ]]; then
  pass "the opener never calls focus-pane (the probe send attaches the PTY)"
else
  fail "the opener never calls focus-pane" "focus=$(cat "$tmp/focus_calls")"
fi

# The creation verbs must not ask for focus either. `--focus true` on a new pane
# or surface is the same theft by another route.
if [[ -s "$tmp/create_calls" ]] && ! grep -q -- '--focus true' "$tmp/create_calls"; then
  pass "the surface is not created --focus true"
else
  fail "the surface is not created --focus true" "create=$(cat "$tmp/create_calls" 2>/dev/null)"
fi

# Ctrl-U precedes each probe, on the SAME handle the probe uses. %q-quoted in the
# log, so the raw 0x15 byte shows up as $'\025' rather than mangling the line.
clears=$(grep -c "\\\$'\\\\025'" "$tmp/send_calls" 2>/dev/null || true)
misaddressed=$(grep "\\\$'\\\\025'" "$tmp/send_calls" 2>/dev/null \
  | grep -vc -- '--surface SURF-NEW' || true)
if [[ "${clears:-0}" -ge 1 && "${misaddressed:-0}" -eq 0 ]]; then
  pass "each probe is preceded by a Ctrl-U on the same handle"
else
  fail "each probe is preceded by a Ctrl-U on the same handle" \
       "clears=$clears misaddressed=$misaddressed sends=$(cat "$tmp/send_calls" 2>/dev/null)"
fi

plain_reads=$(grep -vc -- '--scrollback' "$tmp/read_calls" 2>/dev/null || true)
if [[ -s "$tmp/read_calls" && "${plain_reads:-1}" -eq 0 ]]; then
  pass "every readiness read carries --scrollback (scroll-immune)"
else
  fail "every readiness read carries --scrollback (scroll-immune)" \
       "reads=$(cat "$tmp/read_calls" 2>/dev/null)"
fi

# The probe and the reads address the surface by its stable UUID, and never with
# an empty handle — cmux would resolve that to the FOCUSED surface.
if ! grep -qE -- "--(surface|workspace) ''" "$tmp/send_calls" "$tmp/read_calls" 2>/dev/null; then
  pass "no send or read goes out with an empty handle"
else
  fail "no send or read goes out with an empty handle" \
       "sends=$(cat "$tmp/send_calls" 2>/dev/null) reads=$(cat "$tmp/read_calls" 2>/dev/null)"
fi
rm -rf "$tmp"

# A PTY that never echoes is exit 3 with a diagnostic — and the diagnostic must
# not send the reader back to focus-pane, which is the thing we removed.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-ready-XXXXXX"); make_shim "$tmp"
PATH="$tmp/bin:$PATH" CMUX_FAKE_STATE="$tmp" CMUX_FAKE_NEVER_READY=1 \
  bash "$OPENER" --caller --wait-ready --wait-ready-timeout 2 --title "never ready" --json \
  >/dev/null 2>"$tmp/err.txt"
rc=$?
if [[ $rc -eq 3 ]]; then
  pass "a PTY that never echoes the probe exits 3"
else
  fail "a PTY that never echoes the probe exits 3" "rc=$rc err=$(cat "$tmp/err.txt")"
fi
if ! grep -q 'focus-pane' "$tmp/err.txt"; then
  pass "…and its diagnostic does not recommend focus-pane"
else
  fail "…and its diagnostic does not recommend focus-pane" "err=$(cat "$tmp/err.txt")"
fi
rm -rf "$tmp"

echo ""
echo "surface-ready-hygiene: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
