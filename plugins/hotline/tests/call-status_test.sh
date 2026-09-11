#!/usr/bin/env bash
# =============================================================================
# Tests for hotline call-status: the shared call-registry reader and the
# read-only skill script that prints its records as JSON lines.
#
# Every case runs against a COPY of tests/fixtures/call-registry in a temp dir
# pointed at by HOTLINE_SESSIONS_DIR, so the real ~/.agents-hotline registry is
# never read or touched.
#
# Usage: bash plugins/hotline/tests/call-status_test.sh
# Exit 0 on success; exit 1 with failing case names on any failure.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/call-registry"
SHAPES="$SCRIPT_DIR/fixtures/call-registry-shapes"
CALL_STATUS="$SCRIPT_DIR/../skills/call-status/scripts/call-status.sh"

PASS=0
FAIL=0
FAILED_CASES=()

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

REGISTRY="$SANDBOX/sessions"
mkdir -p "$REGISTRY"
cp "$FIXTURES"/*.json "$REGISTRY/"

CALLER_SID="aaaaaaaa-1111-2222-3333-444444444444"
CALLEE_ONE="bbbbbbbb-5555-6666-7777-888888888888"
CALLEE_TWO="cccccccc-9999-aaaa-bbbb-cccccccccccc"
LEGACY_CALLER="dddddddd-0000-1111-2222-333333333333"
LEGACY_CALLEE="eeeeeeee-4444-5555-6666-777777777777"

# ---- run once against the full fixture registry -----------------------------

OUT="$SANDBOX/out.jsonl"
ERR="$SANDBOX/out.err"
HOTLINE_SESSIONS_DIR="$REGISTRY" bash "$CALL_STATUS" > "$OUT" 2> "$ERR"
STATUS=$?

if [[ $STATUS -eq 0 ]]; then
  pass "malformed file alongside valid ones is not fatal (exit 0)"
else
  fail "malformed file alongside valid ones is not fatal (exit 0, got: $STATUS)"
fi

if [[ $(wc -l < "$OUT" | tr -d ' ') == "3" ]]; then
  pass "every valid entry survives the malformed one (3 records)"
else
  fail "every valid entry survives the malformed one (3 records, got: $(wc -l < "$OUT" | tr -d ' '))"
fi

if grep -q "ffffffff-8888-9999-aaaa-bbbbbbbbbbbb.json" "$ERR"; then
  pass "malformed file is named in a stderr warning"
else
  fail "malformed file is named in a stderr warning (stderr: $(cat "$ERR"))"
fi

if ! jq -e . "$OUT" >/dev/null 2>&1; then
  fail "every line is valid JSON"
else
  pass "every line is valid JSON"
fi

# ---- case: one caller with multiple callees ---------------------------------

MULTI=$(jq -r --arg c "$CALLER_SID" 'select(.caller_session_id==$c) | .callee_session_id' "$OUT" | sort | tr '\n' ' ')
EXPECTED_MULTI=$(printf '%s\n%s\n' "$CALLEE_ONE" "$CALLEE_TWO" | sort | tr '\n' ' ')
if [[ "$MULTI" == "$EXPECTED_MULTI" ]]; then
  pass "one caller yields both of its callees"
else
  fail "one caller yields both of its callees (got: $MULTI)"
fi

ONE=$(jq -c --arg s "$CALLEE_ONE" 'select(.callee_session_id==$s)' "$OUT")
if [[ $(jq -r '.target' <<<"$ONE") == "/tmp/callee-one" \
   && $(jq -r '.caller_path' <<<"$ONE") == "/tmp/boss-ws" \
   && $(jq -r '.host_handle' <<<"$ONE") == "surface-uuid-one" \
   && $(jq -r '.transport' <<<"$ONE") == "cmux" \
   && $(jq -r '.mode' <<<"$ONE") == "work_order" \
   && $(jq -r '.last_contact' <<<"$ONE") == "1750000300" ]]; then
  pass "first callee record carries exact target, host handle, transport, mode, last contact"
else
  fail "first callee record carries exact target, host handle, transport, mode, last contact (got: $ONE)"
fi

TWO=$(jq -c --arg s "$CALLEE_TWO" 'select(.callee_session_id==$s)' "$OUT")
if [[ $(jq -r '.host_handle' <<<"$TWO") == "herdr-agent-two" \
   && $(jq -r '.transport' <<<"$TWO") == "herdr" \
   && $(jq -r '.remote' <<<"$TWO") == "linuxbox" ]]; then
  pass "second callee record carries the herdr handle and remote box"
else
  fail "second callee record carries the herdr handle and remote box (got: $TWO)"
fi

# ---- case: legacy entry (no caller_session_id) ------------------------------
# Pre-0.31.0 files carry neither caller_session_id nor transport/surface_ref;
# the filename has always been the caller's session id.

LEGACY=$(jq -c --arg s "$LEGACY_CALLEE" 'select(.callee_session_id==$s)' "$OUT")
if [[ $(jq -r '.caller_session_id' <<<"$LEGACY") == "$LEGACY_CALLER" \
   && $(jq -r '.target' <<<"$LEGACY") == "/tmp/legacy-callee" \
   && $(jq -r '.host_handle' <<<"$LEGACY") == "" \
   && $(jq -r '.transport' <<<"$LEGACY") == "" ]]; then
  pass "legacy entry takes its caller session id from the filename"
else
  fail "legacy entry takes its caller session id from the filename (got: $LEGACY)"
fi

# ---- case: read-only --------------------------------------------------------

BEFORE=$(cd "$REGISTRY" && ls -1 | while read -r f; do printf '%s ' "$(cksum < "$f")"; done)
HOTLINE_SESSIONS_DIR="$REGISTRY" bash "$CALL_STATUS" >/dev/null 2>&1
AFTER=$(cd "$REGISTRY" && ls -1 | while read -r f; do printf '%s ' "$(cksum < "$f")"; done)
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass "registry bytes are untouched"
else
  fail "registry bytes are untouched"
fi

# ---- case: empty registry ---------------------------------------------------

EMPTY_DIR="$SANDBOX/empty"
mkdir -p "$EMPTY_DIR"
EMPTY_OUT=$(HOTLINE_SESSIONS_DIR="$EMPTY_DIR" bash "$CALL_STATUS" 2>/dev/null)
EMPTY_STATUS=$?
if [[ $EMPTY_STATUS -eq 0 && -z "$EMPTY_OUT" ]]; then
  pass "empty registry gives empty output and exit 0"
else
  fail "empty registry gives empty output and exit 0 (status: $EMPTY_STATUS, out: $EMPTY_OUT)"
fi

# ---- case: missing registry -------------------------------------------------

GONE_OUT=$(HOTLINE_SESSIONS_DIR="$SANDBOX/never-existed" bash "$CALL_STATUS" 2>/dev/null)
GONE_STATUS=$?
if [[ $GONE_STATUS -eq 0 && -z "$GONE_OUT" ]]; then
  pass "missing registry gives empty output and exit 0"
else
  fail "missing registry gives empty output and exit 0 (status: $GONE_STATUS, out: $GONE_OUT)"
fi

# ---- case: skill script runs from any working directory ---------------------

CWD_OUT=$(cd / && HOTLINE_SESSIONS_DIR="$REGISTRY" bash "$CALL_STATUS" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$CWD_OUT" == "3" ]]; then
  pass "skill script resolves the shared reader from any cwd"
else
  fail "skill script resolves the shared reader from any cwd (got: $CWD_OUT)"
fi

# ---- case: --plugin-root addresses the shared reader ------------------------
# How the skill invokes it: the plugin root is handed in rather than counted out
# in parent directories.

ROOT_OUT=$(cd / && HOTLINE_SESSIONS_DIR="$REGISTRY" bash "$CALL_STATUS" \
  --plugin-root "$SCRIPT_DIR/.." 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ROOT_OUT" == "3" ]]; then
  pass "--plugin-root resolves the shared reader"
else
  fail "--plugin-root resolves the shared reader (got: $ROOT_OUT)"
fi

BOGUS_ERR=$(HOTLINE_SESSIONS_DIR="$REGISTRY" bash "$CALL_STATUS" \
  --plugin-root "$SANDBOX/no-such-plugin" 2>&1 >/dev/null)
BOGUS_STATUS=$?
if [[ $BOGUS_STATUS -eq 1 && "$BOGUS_ERR" == *"no-such-plugin/scripts/call-registry.mjs"* ]]; then
  pass "a wrong --plugin-root fails loudly instead of being ignored"
else
  fail "a wrong --plugin-root fails loudly instead of being ignored (status: $BOGUS_STATUS, err: $BOGUS_ERR)"
fi

# --plugin-root with no value used to leave the arg list untouched and spin
# forever (`shift 2 || true` with one arg left), so this case is bounded by
# `timeout` on purpose: a regression hangs the suite rather than failing it.
MISSING_ERR=$(timeout 5 bash "$CALL_STATUS" --plugin-root 2>&1 >/dev/null)
MISSING_STATUS=$?
if [[ $MISSING_STATUS -eq 2 && "$MISSING_ERR" == *"--plugin-root needs a directory"* ]]; then
  pass "--plugin-root with no value exits 2 instead of looping"
else
  fail "--plugin-root with no value exits 2 instead of looping (status: $MISSING_STATUS, err: $MISSING_ERR)"
fi

# ---- case: degenerate registry shapes ---------------------------------------
# A top-level `null` parses fine, so the reader's `reg &&` guards are what keep
# it from taking down the whole run; a connection that is not an object costs
# only itself.

SHAPES_DIR="$SANDBOX/shapes"
mkdir -p "$SHAPES_DIR"
cp "$SHAPES"/*.json "$SHAPES_DIR/"
SHAPES_OUT="$SANDBOX/shapes.jsonl"
SHAPES_ERR="$SANDBOX/shapes.err"
HOTLINE_SESSIONS_DIR="$SHAPES_DIR" bash "$CALL_STATUS" > "$SHAPES_OUT" 2> "$SHAPES_ERR"
SHAPES_STATUS=$?

if [[ $SHAPES_STATUS -eq 0 ]]; then
  pass "a null-bodied registry file does not take down the run (exit 0)"
else
  fail "a null-bodied registry file does not take down the run (exit 0, got: $SHAPES_STATUS, err: $(cat "$SHAPES_ERR"))"
fi

if [[ $(jq -r 'select(.callee_session_id=="99999999-aaaa-bbbb-cccc-dddddddddddd") | .target' "$SHAPES_OUT") == "/tmp/good-conn"    && $(wc -l < "$SHAPES_OUT" | tr -d ' ') == "1" ]]; then
  pass "the valid connection beside a non-object one survives (1 record)"
else
  fail "the valid connection beside a non-object one survives (1 record, got: $(cat "$SHAPES_OUT"))"
fi

if grep -q "connection /tmp/string-conn: not an object" "$SHAPES_ERR"; then
  pass "a non-object connection is named in a stderr warning"
else
  fail "a non-object connection is named in a stderr warning (stderr: $(cat "$SHAPES_ERR"))"
fi

# ---- summary ----------------------------------------------------------------

echo ""
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
