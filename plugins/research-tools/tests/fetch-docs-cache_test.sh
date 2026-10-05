#!/usr/bin/env bash
# fetch-docs cache-hit short-circuit. curl is stubbed via PATH so a cache miss
# is observable (the stub logs and fails) and nothing touches the network.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/fetch-docs/scripts/fetch-docs.sh"
TMP=$(mktemp -d)
SLUG="fdtest-$$-$RANDOM"
CACHED="/tmp/fetch-docs-${SLUG}.html"
trap 'rm -rf "$TMP" "$CACHED"' EXIT

PASS=0; FAIL=0
pass() { echo "  ok   $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<STUB
#!/usr/bin/env bash
echo called >> "$TMP/curl.log"
exit 7
STUB
chmod +x "$BIN/curl"

# --- a fresh cached file is returned without fetching ------------------------
# Pins the Linux path of the BSD-first mtime lookup. On GNU, `stat -f %m FILE`
# prints FILE's filesystem dump, then fails on the "%m" operand and exits 1;
# the script's if/else then REASSIGNS mtime from `stat -c %Y`. Collapsing that
# into `mtime=$(stat -f ... || stat -c ...)` would keep the dump in the capture
# and break the TTL check (the handoff session-start bug).
printf '<html><body>cached</body></html>\n' > "$CACHED"
OUT=$(PATH="$BIN:$PATH" bash "$SCRIPT" --slug="$SLUG" "https://example.invalid/page" 2>"$TMP/err")
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "$CACHED" ] && [ ! -f "$TMP/curl.log" ]; then
  pass "fresh cache hit returns the cached path without calling curl"
else
  fail "cache hit (rc=$RC out=$OUT curl=$( [ -f "$TMP/curl.log" ] && echo called || echo no) err=$(cat "$TMP/err"))"
fi

# --- an expired cached file is refetched -------------------------------------
touch -d '@1000000000' "$CACHED"
PATH="$BIN:$PATH" bash "$SCRIPT" --slug="$SLUG" "https://example.invalid/page" >/dev/null 2>&1
if [ -f "$TMP/curl.log" ]; then
  pass "expired cache triggers a fetch"
else
  fail "expired cache did not trigger a fetch"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
