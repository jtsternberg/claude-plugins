#!/usr/bin/env bash
# =============================================================================
# Headless STATUS classification (claude-plugins-x5zb): a `claude -p` callee whose
# final text ends on AWAITING_REVIEW or BLOCKED must not read as exit 0 "work
# done". Drives the real headless-call-async.sh against a stub `claude` that
# prints a stream-json result, then wait-for-response.sh on the call dir.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAL_SCRIPTS="$ROOT/skills/dial/scripts"
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/calls" "$TMP/target"
# The stub answers with whatever result text RESULT_FILE holds.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
jq -nc --rawfile r "$RESULT_FILE" '{type:"result",session_id:"sess-h",result:$r}'
STUB
chmod +x "$TMP/bin/claude"

# run_headless <result text> → sets RC, OUT, CD
run_headless() {
  printf '%s' "$1" > "$TMP/result.txt"
  local launch
  launch=$(env PATH="$TMP/bin:$PATH" HOME="$TMP/home" HOTLINE_CALL_HOME="$TMP/calls" \
    RESULT_FILE="$TMP/result.txt" \
    bash "$DIAL_SCRIPTS/headless-call-async.sh" --cwd "$TMP/target" --prompt "do it" 2>/dev/null)
  CD=$(jq -r '.call_dir' <<<"$launch")
  OUT=$(env HOME="$TMP/home" HOTLINE_POLL_SLEEP=0.1 bash "$DIAL_SCRIPTS/wait-for-response.sh" "$CD" --timeout 20 2>/dev/null); RC=$?
}

run_headless $'which schema should it target?\n\nSTATUS: BLOCKED'
[[ $RC -eq 7 && "$(jq -r '.blocked' <<<"$OUT")" == "true" ]] \
  && pass "headless: turn ending on BLOCKED → exit 7, blocked:true" \
  || fail "headless: turn ending on BLOCKED → exit 7, blocked:true" "rc=$RC out=$OUT"
[[ "$(jq -r '.blocked' "$CD/response.json" 2>/dev/null)" == "true" ]] \
  && pass "headless: response.json carries blocked:true" \
  || fail "headless: response.json carries blocked:true" "$(cat "$CD/response.json" 2>/dev/null)"

run_headless $'step 1 of 3 done\n\nSTATUS: AWAITING_REVIEW'
[[ $RC -eq 4 && "$(jq -r '.awaiting_review' <<<"$OUT")" == "true" ]] \
  && pass "headless: AWAITING_REVIEW → exit 4, awaiting_review:true" \
  || fail "headless: AWAITING_REVIEW → exit 4, awaiting_review:true" "rc=$RC out=$OUT"

run_headless $'all done\n\nSTATUS: WORK_COMPLETE'
if [[ $RC -eq 0 ]] && ! jq -e 'has("blocked") or has("awaiting_review")' <<<"$OUT" >/dev/null 2>&1; then
  pass "headless: WORK_COMPLETE → exit 0, no markers"
else
  fail "headless: WORK_COMPLETE → exit 0, no markers" "rc=$RC out=$OUT"
fi

run_headless $'migrated\nSTATUS: DONE\none more thing?\nSTATUS: BLOCKED'
[[ $RC -eq 0 ]] && pass "headless: an earlier DONE wins over a later BLOCKED" \
  || fail "headless: an earlier DONE wins over a later BLOCKED" "rc=$RC out=$OUT"

run_headless $'question?\nSTATUS: BLOCKED\nSTATUS: WORK_IN_PROGRESS\nfound it'
[[ $RC -eq 0 ]] && pass "headless: BLOCKED superseded by a later WORK_IN_PROGRESS → exit 0" \
  || fail "headless: BLOCKED superseded by a later WORK_IN_PROGRESS → exit 0" "rc=$RC out=$OUT"

run_headless 'plain answer, no STATUS at all'
[[ $RC -eq 0 ]] && pass "headless: no STATUS → exit 0 (unchanged)" \
  || fail "headless: no STATUS → exit 0 (unchanged)" "rc=$RC out=$OUT"

run_headless $'question?\nSTATUS: BLOCKED call_id=0123abcd0123abcd'
[[ $RC -eq 7 ]] && pass "headless: a STATUS carrying a call_id suffix still classifies" \
  || fail "headless: a STATUS carrying a call_id suffix still classifies" "rc=$RC out=$OUT"

echo ""
echo "headless-status: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
