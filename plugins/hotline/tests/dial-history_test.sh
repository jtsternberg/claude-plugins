#!/usr/bin/env bash
# =============================================================================
# Regression tests for dial-history.sh
#
# The bug this suite pins: entries were written with pretty-printed `jq -n`
# (~6 lines each) into a file treated as JSONL, and the cap trimmed to the last
# 100 LINES. Once a workspace crossed 100 lines the trim sliced an object in
# half and the file became permanently unparseable — 6 real files on the
# author's machine were already corrupt when this was found.
#
# HOME is redirected per-case so nothing touches the real
# ~/.agents-hotline/identities.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/dial-history.sh"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

# Each case gets a throwaway HOME so the history lands in a temp tree.
new_home() { mktemp -d /tmp/hotline-dh-test-XXXXXX; }

history_file() {
  # $1 = fake HOME, $2 = receiver cwd
  local h="$1" cwd="$2" canon hash
  canon=$(realpath "$cwd" 2>/dev/null || echo "$cwd")
  hash=$(echo -n "$canon" | shasum -a 256 | cut -c1-16)
  echo "$h/.agents-hotline/identities/${hash}.dial_history.jsonl"
}

dh() { local h="$1"; shift; HOME="$h" bash "$SCRIPT_UNDER_TEST" "$@"; }

echo "dial-history.sh"

# --- append writes ONE compact line per entry -------------------------------
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
dh "$H" append --cwd "$RCVR" --session caller-sess-1 --caller /some/caller --mode quick_call
dh "$H" append --cwd "$RCVR" --session caller-sess-2 --caller /some/caller --mode work_order
HF=$(history_file "$H" "$RCVR")

if [[ -f "$HF" ]]; then
  pass "append creates the history file keyed by receiver cwd"
else
  fail "append creates the history file keyed by receiver cwd" "missing: $HF"
fi

lines=$(wc -l < "$HF" | tr -d ' ')
if [[ "$lines" -eq 2 ]]; then
  pass "two appends produce exactly two lines (compact)"
else
  fail "two appends produce exactly two lines (compact)" "got $lines lines"
fi

if jq -e . "$HF" >/dev/null 2>&1; then
  pass "history file is valid JSON stream"
else
  fail "history file is valid JSON stream" "$(cat "$HF")"
fi

got=$(jq -r '.session_id' "$HF" | tr '\n' ',')
if [[ "$got" == "caller-sess-1,caller-sess-2," ]]; then
  pass "entries preserve session_id and order"
else
  fail "entries preserve session_id and order" "got: $got"
fi

# Schema compatibility: the original four keys, and no null receiver_session.
keys=$(jq -c 'keys_unsorted' "$HF" | head -1)
if [[ "$keys" == '["session_id","caller","mode","timestamp"]' ]]; then
  pass "omits receiver_session entirely when not supplied"
else
  fail "omits receiver_session entirely when not supplied" "got: $keys"
fi
rm -rf "$H"

# --- receiver_session is recorded when supplied -----------------------------
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
dh "$H" append --cwd "$RCVR" --session caller-sess --caller /c --mode quick_call \
  --receiver-session callee-sess
HF=$(history_file "$H" "$RCVR")
if [[ "$(jq -r '.receiver_session' "$HF")" == "callee-sess" ]]; then
  pass "--receiver-session is recorded"
else
  fail "--receiver-session is recorded" "$(cat "$HF")"
fi
rm -rf "$H"

# --- the cap counts ENTRIES, not lines --------------------------------------
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
for i in $(seq 1 105); do
  dh "$H" append --cwd "$RCVR" --session "s$i" --caller /c --mode quick_call
done
HF=$(history_file "$H" "$RCVR")
entries=$(wc -l < "$HF" | tr -d ' ')
if [[ "$entries" -eq 100 ]]; then
  pass "cap keeps exactly 100 entries"
else
  fail "cap keeps exactly 100 entries" "got $entries"
fi
if jq -e . "$HF" >/dev/null 2>&1; then
  pass "file still parses after the cap fires"
else
  fail "file still parses after the cap fires" "corrupted at the cap boundary"
fi
newest=$(jq -r '.session_id' "$HF" | tail -1)
oldest=$(jq -r '.session_id' "$HF" | head -1)
if [[ "$newest" == "s105" && "$oldest" == "s6" ]]; then
  pass "cap trims the OLDEST entries"
else
  fail "cap trims the OLDEST entries" "oldest=$oldest newest=$newest"
fi
rm -rf "$H"

# --- legacy pretty-printed file is normalized on append --------------------
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
HF=$(history_file "$H" "$RCVR")
mkdir -p "$(dirname "$HF")"
cat > "$HF" <<'EOF'
{
  "session_id": "legacy-1",
  "caller": "/old/caller",
  "mode": "work_order",
  "timestamp": 1700000000
}
{
  "session_id": "legacy-2",
  "caller": "/old/caller",
  "mode": "quick_call",
  "timestamp": 1700000001
}
EOF
dh "$H" append --cwd "$RCVR" --session new-1 --caller /new --mode quick_call
lines=$(wc -l < "$HF" | tr -d ' ')
if [[ "$lines" -eq 3 ]]; then
  pass "legacy pretty-printed entries are compacted on append"
else
  fail "legacy pretty-printed entries are compacted on append" "got $lines lines: $(cat "$HF")"
fi
ids=$(jq -r '.session_id' "$HF" | tr '\n' ',')
if [[ "$ids" == "legacy-1,legacy-2,new-1," ]]; then
  pass "legacy entries survive normalization with order intact"
else
  fail "legacy entries survive normalization with order intact" "got: $ids"
fi
rm -rf "$H"

# --- half-trimmed (already corrupt) file is salvaged ------------------------
# Mirrors what the old line-based cap actually produced: the file starts
# mid-object. The leading fragment is unrecoverable; every whole entry after it
# must survive.
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
HF=$(history_file "$H" "$RCVR")
mkdir -p "$(dirname "$HF")"
cat > "$HF" <<'EOF'
  "caller": "/sliced/caller",
  "mode": "work_order",
  "timestamp": 1700000000
}
{
  "session_id": "survivor-1",
  "caller": "/old/caller",
  "mode": "quick_call",
  "timestamp": 1700000001
}
EOF
if jq -e . "$HF" >/dev/null 2>&1; then
  fail "fixture is genuinely corrupt before normalize" "fixture parsed — bad fixture"
else
  pass "fixture is genuinely corrupt before normalize"
fi

dh "$H" normalize --cwd "$RCVR"
if jq -e . "$HF" >/dev/null 2>&1; then
  pass "normalize repairs a half-trimmed file"
else
  fail "normalize repairs a half-trimmed file" "$(cat "$HF")"
fi
ids=$(jq -r '.session_id' "$HF" | tr '\n' ',')
if [[ "$ids" == "survivor-1," ]]; then
  pass "normalize keeps every whole entry after the slice"
else
  fail "normalize keeps every whole entry after the slice" "got: $ids"
fi

# And a subsequent append lands cleanly on the repaired file.
dh "$H" append --cwd "$RCVR" --session after-repair --caller /c --mode quick_call
ids=$(jq -r '.session_id' "$HF" | tr '\n' ',')
if [[ "$ids" == "survivor-1,after-repair," ]]; then
  pass "append works on a repaired file"
else
  fail "append works on a repaired file" "got: $ids"
fi
rm -rf "$H"

# --- unsalvageable garbage is preserved, not silently dropped --------------
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
HF=$(history_file "$H" "$RCVR")
mkdir -p "$(dirname "$HF")"
printf 'not json at all\nstill not json\n' > "$HF"
dh "$H" normalize --cwd "$RCVR"
if [[ ! -s "$HF" ]] && ls "${HF}.corrupt."* >/dev/null 2>&1; then
  pass "unsalvageable file is emptied but preserved as .corrupt.<ts>"
else
  fail "unsalvageable file is emptied but preserved as .corrupt.<ts>" \
       "file=$(cat "$HF" 2>/dev/null) backups=$(ls "$(dirname "$HF")" 2>/dev/null)"
fi
rm -rf "$H"

# --- read round-trips what append wrote ------------------------------------
H=$(new_home); RCVR="$H/workspace"; mkdir -p "$RCVR"
dh "$H" append --cwd "$RCVR" --session r1 --caller /c --mode work_order
out=$(dh "$H" read --cwd "$RCVR")
if printf '%s' "$out" | jq -e 'select(.session_id == "r1")' >/dev/null 2>&1; then
  pass "read returns appended entries"
else
  fail "read returns appended entries" "got: $out"
fi
rm -rf "$H"

# --- append still validates required args ----------------------------------
H=$(new_home)
if dh "$H" append --cwd "$H" --session only-session >/dev/null 2>&1; then
  fail "append without --caller/--mode exits non-zero" "exited 0"
else
  pass "append without --caller/--mode exits non-zero"
fi
rm -rf "$H"

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
