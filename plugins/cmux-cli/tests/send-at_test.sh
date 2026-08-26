#!/usr/bin/env bash
# =============================================================================
# send-at: behavior of the deterministic delivery helper + doc canary.
#
# Driven entirely by a shimmed `cmux` on PATH — never touches real cmux, so it
# runs on Linux CI too. The shim records every invocation to a log and returns
# canned tree/read-screen output, letting us assert the hard V1 contract:
#   • exact UUID resolved from ONE tree snapshot -> its workspace
#   • text sent, THEN a SEPARATE send-key Enter (no bundled newline)
#   • surface gone  -> status surface_gone, exit 3, and NOTHING sent
#   • send fails     -> status send_failed, exit 4, and NO Enter sent
#   • read-screen check is informational (does not change the exit code)
# The SKILL.md canary pins the no-fallback / wake-this-session / honest-envelope
# prose that is the whole point of the skill.
# =============================================================================
set -u

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PLUGIN_DIR/skills/send-at/scripts/send-to-surface.sh"
SKILL_MD="$PLUGIN_DIR/skills/send-at/SKILL.md"

PASS=0
FAIL=0
FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

command -v jq >/dev/null 2>&1 || {
  echo "send-at: jq not installed — skipping suite"
  echo "0 passed, 0 failed (skipped: jq missing)"
  exit 0
}

# --- Sandbox with a shimmed `cmux` on PATH ----------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
CALLLOG="$SANDBOX/cmux.log"

# Known handles for the canned tree.
GOOD_SURFACE="AAAAAAAA-1111-2222-3333-444444444444"
GOOD_WS="BBBBBBBB-5555-6666-7777-888888888888"

# The shim reads two env knobs so individual cases can steer failures:
#   SHIM_SEND_RC     — exit code for `cmux send`      (default 0)
#   SHIM_SCREEN_TEXT — what `cmux read-screen` prints (default empty)
cat > "$BIN/cmux" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$CALLLOG"
cmd="\${1:-}"
case "\$cmd" in
  tree)
    cat <<'JSON'
{ "windows": [ { "ref": "window:1", "id": "W",
  "workspaces": [ { "ref": "workspace:1", "id": "$GOOD_WS", "title": "demo",
    "panes": [ { "ref": "pane:1", "id": "P",
      "surfaces": [ { "ref": "surface:1", "id": "$GOOD_SURFACE", "type": "terminal", "title": "t" } ] } ] } ] } ] }
JSON
    ;;
  send)      rc="\${SHIM_SEND_RC:-0}"; [ "\$rc" = 0 ] && echo "OK surface:1 workspace:1"; exit "\$rc" ;;
  send-key)  echo "OK surface:1 workspace:1"; exit 0 ;;
  read-screen) printf '%s\n' "\${SHIM_SCREEN_TEXT:-}" ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$BIN/cmux"

run() {  # run <extra-env> -- <args...> ; sets OUT/RC, resets CALLLOG
  # env_kv is one "NAME=value" string (value may contain spaces) or empty.
  # Passed as a SINGLE argument to `env` so spaces don't word-split into argv.
  : > "$CALLLOG"
  local env_kv="$1"; shift; [[ "$1" == "--" ]] && shift
  if [[ -n "$env_kv" ]]; then
    OUT="$(PATH="$BIN:$PATH" env "$env_kv" bash "$SCRIPT" "$@" 2>/dev/null)"
  else
    OUT="$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>/dev/null)"
  fi
  RC=$?
}

# --- 1. Happy path: resolve, send, then a SEPARATE Enter --------------------
run "" -- --surface "$GOOD_SURFACE" --prompt "hello world"
[[ $RC -eq 0 ]] && pass "happy path exits 0" || fail "happy path exits 0" "rc=$RC out=$OUT"
[[ "$OUT" == sent* ]] && pass "happy path prints 'sent'" || fail "happy path prints 'sent'" "out=$OUT"

# stdout is ONLY the status word — real cmux send/send-key print "OK surface:N
# workspace:N" to stdout, and that chatter must not leak into the parseable
# output (a live smoke caught this; the shim now reproduces the chatter).
if [[ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" == "0" ]] && ! printf '%s' "$OUT" | grep -q 'OK surface'; then
  pass "stdout is only the status word (no cmux 'OK' chatter)"
else
  fail "stdout is only the status word (no cmux 'OK' chatter)" "out=[$OUT]"
fi

SEND_LINE="$(grep -n '^send ' "$CALLLOG" | head -1)"
if printf '%s' "$SEND_LINE" | grep -q -- "--workspace $GOOD_WS" \
   && printf '%s' "$SEND_LINE" | grep -q -- "--surface $GOOD_SURFACE"; then
  pass "send targets the resolved workspace + exact surface"
else
  fail "send targets the resolved workspace + exact surface" "send line: $SEND_LINE"
fi

# The Enter must be a distinct send-key call AFTER the text send, and the send
# payload must NOT carry a trailing newline (the TUI/Ink submit gotcha).
send_ln=$(grep -n '^send ' "$CALLLOG" | head -1 | cut -d: -f1)
enter_ln=$(grep -n '^send-key .*Enter' "$CALLLOG" | head -1 | cut -d: -f1)
if [[ -n "$send_ln" && -n "$enter_ln" && "$send_ln" -lt "$enter_ln" ]]; then
  pass "send happens before a separate send-key Enter"
else
  fail "send happens before a separate send-key Enter" "send_ln=$send_ln enter_ln=$enter_ln"
fi
if grep -q 'hello world' "$CALLLOG" && ! grep -qE '^send .*hello world\\n' "$CALLLOG"; then
  pass "text send carries no bundled '\\n'"
else
  fail "text send carries no bundled '\\n'" "$(grep '^send ' "$CALLLOG")"
fi

# --- 2. read-screen check is informational ----------------------------------
run "SHIM_SCREEN_TEXT=hello world is on the screen" -- --surface "$GOOD_SURFACE" --prompt "hello world"
[[ "$OUT" == *"delivery_observed=true"* ]] \
  && pass "observed=true when the probe appears on screen" \
  || fail "observed=true when the probe appears on screen" "out=$OUT"

run "SHIM_SCREEN_TEXT=totally-unrelated" -- --surface "$GOOD_SURFACE" --prompt "hello world"
if [[ "$OUT" == *"delivery_observed=false"* && $RC -eq 0 ]]; then
  pass "observed=false does NOT change the success exit code"
else
  fail "observed=false does NOT change the success exit code" "rc=$RC out=$OUT"
fi

# --- 3. Surface gone: report + STOP, nothing sent ---------------------------
run "" -- --surface "99999999-0000-0000-0000-000000000000" --prompt "nope"
[[ "$OUT" == "surface_gone" && $RC -eq 3 ]] \
  && pass "absent UUID -> surface_gone, exit 3" \
  || fail "absent UUID -> surface_gone, exit 3" "rc=$RC out=$OUT"
if grep -qE '^send ' "$CALLLOG"; then
  fail "surface_gone sends NOTHING" "a send was attempted: $(grep '^send ' "$CALLLOG")"
else
  pass "surface_gone sends NOTHING (no fallback)"
fi

# --- 4. send fails: report + STOP, no Enter ---------------------------------
run "SHIM_SEND_RC=1" -- --surface "$GOOD_SURFACE" --prompt "hi"
[[ "$OUT" == "send_failed" && $RC -eq 4 ]] \
  && pass "send failure -> send_failed, exit 4" \
  || fail "send failure -> send_failed, exit 4" "rc=$RC out=$OUT"
if grep -qE '^send-key .*Enter' "$CALLLOG"; then
  fail "send failure sends NO Enter" "an Enter was sent: $(grep '^send-key' "$CALLLOG")"
else
  pass "send failure sends NO Enter"
fi

# --- 5. Usage errors --------------------------------------------------------
run "" -- --prompt "no surface"
[[ "$OUT" == "error" && $RC -eq 2 ]] \
  && pass "missing --surface -> error, exit 2" \
  || fail "missing --surface -> error, exit 2" "rc=$RC out=$OUT"

run "" -- --surface "$GOOD_SURFACE"
[[ "$OUT" == "error" && $RC -eq 2 ]] \
  && pass "missing prompt -> error, exit 2" \
  || fail "missing prompt -> error, exit 2" "rc=$RC out=$OUT"

# --- 5b. --prompt-file: the ps-safe payload path ----------------------------
PF="$SANDBOX/prompt.txt"; printf 'from a file' > "$PF"
run "" -- --surface "$GOOD_SURFACE" --prompt-file "$PF"
if [[ "$OUT" == sent* && $RC -eq 0 ]] && grep -q 'from a file' "$CALLLOG"; then
  pass "--prompt-file delivers the file's contents"
else
  fail "--prompt-file delivers the file's contents" "rc=$RC out=$OUT log=$(grep '^send ' "$CALLLOG")"
fi

run "" -- --surface "$GOOD_SURFACE" --prompt-file "$SANDBOX/does-not-exist"
[[ "$OUT" == "error" && $RC -eq 2 ]] \
  && pass "missing --prompt-file target -> error, exit 2" \
  || fail "missing --prompt-file target -> error, exit 2" "rc=$RC out=$OUT"

run "" -- --surface "$GOOD_SURFACE" --prompt "x" --prompt-file "$PF"
[[ "$OUT" == "error" && $RC -eq 2 ]] \
  && pass "--prompt + --prompt-file together -> error, exit 2" \
  || fail "--prompt + --prompt-file together -> error, exit 2" "rc=$RC out=$OUT"

# --- 6. SKILL.md doc canary: the contract + honesty must stay stated --------
canary() {  # canary <pattern> <label>
  grep -qiE "$1" "$SKILL_MD" && pass "SKILL.md: $2" || fail "SKILL.md: $2" "missing /$1/"
}
canary 'exact surface|exact UUID'                        "states exact-surface-only"
canary 'no fallback'                                     "states no-fallback"
canary 'fork'                                            "forbids forking a session"
canary 'launchd|cron'                                    "forbids launchd/cron (no cmux ancestry)"
canary 'ancestry'                                        "explains the cmux-ancestry constraint"
canary 'best-effort|not a durable'                       "frames it as best-effort, not durable"
canary 'stay alive|stays alive|alive at the target'      "states the session-must-stay-alive envelope"
canary 'functions\.wait'                                 "names Codex functions.wait active-turn wait"
canary 'run_in_background|background until'               "names the Claude background wake path"
canary 'informational'                                   "calls the read-screen check informational"

echo ""
echo "send-at: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
