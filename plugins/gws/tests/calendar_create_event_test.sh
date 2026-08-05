#!/usr/bin/env bash
# Tests for calendar-create-event.sh start/end handling.
#
# Stubs `gws` on PATH — never reaches the real Calendar API. The stub writes the
# request body it was handed to $STUB_BODY_OUT so we can assert on the exact
# JSON shape, which is the whole point: all-day events need {"date": ...} and
# timed events need {"dateTime": ...}, and mixing them is a silent 400.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_ROOT/scripts/calendar-create-event.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- gws stub -----------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gws" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  # Mirror the real CLI: keyring noise on stderr, JSON on stdout.
  echo "Using keyring backend: keyring" >&2
  echo '{"user":"stub@example.com","has_refresh_token":true,"encryption_valid":true,"token_valid":true}'
  exit 0
fi
if [[ "$1" == "calendar" && "$2" == "events" && "$3" == "insert" ]]; then
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--json" ]]; then j=$((i+1)); printf '%s' "${!j}" > "$STUB_BODY_OUT"; fi
  done
  echo '{"id":"stub","summary":"stub","start":{},"end":{}}'
  exit 0
fi
echo "stub: unhandled invocation: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gws"

export PATH="$TMP/bin:$PATH"
export STUB_BODY_OUT="$TMP/body.json"
# Point account resolution at an empty dir so the stub's default config wins and
# the test never reads the developer's real ~/.config/gws-accounts.
export GWS_ACCOUNTS_DIR="$TMP/accounts"
mkdir -p "$GWS_ACCOUNTS_DIR"

PASS=0
FAIL=0

# body_field <jq-ish path> — prints start/end as compact JSON
bounds() {
  python3 -c "
import json
d = json.load(open('$STUB_BODY_OUT'))
print(json.dumps({'start': d['start'], 'end': d['end']}, sort_keys=True, separators=(',',':')))"
}

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; }

# assert_bounds <desc> <expected-json> <args...>
assert_bounds() {
  local desc="$1" want="$2"; shift 2
  rm -f "$STUB_BODY_OUT"
  if ! bash "$CREATE" "$@" >/dev/null 2>"$TMP/err"; then
    bad "$desc" "$want" "script exited non-zero: $(tr '\n' ' ' < "$TMP/err")"
    return
  fi
  local got; got="$(bounds)"
  [[ "$got" == "$want" ]] && ok || bad "$desc" "$want" "$got"
}

# assert_rejects <desc> <substring-of-error> <args...>
assert_rejects() {
  local desc="$1" needle="$2"; shift 2
  rm -f "$STUB_BODY_OUT"
  if bash "$CREATE" "$@" >/dev/null 2>"$TMP/err"; then
    bad "$desc" "non-zero exit mentioning '$needle'" "exited 0 and created an event"
    return
  fi
  if grep -qF -e "$needle" "$TMP/err"; then ok
  else bad "$desc" "error mentioning '$needle'" "$(tr '\n' ' ' < "$TMP/err")"; fi
}

# --- all-day ------------------------------------------------------------------

# The regression: date-only start used to be emitted as dateTime and 400 out.
assert_bounds "date-only start implies all-day, one day" \
  '{"end":{"date":"2026-09-29"},"start":{"date":"2026-09-28"}}' \
  --title T --start 2026-09-28

assert_bounds "exclusive --end is passed through" \
  '{"end":{"date":"2026-10-01"},"start":{"date":"2026-09-28"}}' \
  --title T --start 2026-09-28 --end 2026-10-01

assert_bounds "--through is inclusive, so end is through+1" \
  '{"end":{"date":"2026-10-01"},"start":{"date":"2026-09-28"}}' \
  --title T --start 2026-09-28 --through 2026-09-30

assert_bounds "--through crossing a month boundary" \
  '{"end":{"date":"2026-11-01"},"start":{"date":"2026-10-30"}}' \
  --title T --start 2026-10-30 --through 2026-10-31

assert_bounds "--through crossing a leap day" \
  '{"end":{"date":"2028-03-01"},"start":{"date":"2028-02-28"}}' \
  --title T --start 2028-02-28 --through 2028-02-29

assert_bounds "explicit --all-day with date-only start" \
  '{"end":{"date":"2026-09-29"},"start":{"date":"2026-09-28"}}' \
  --title T --all-day --start 2026-09-28

# All-day events carry no timeZone even when --tz is passed.
rm -f "$STUB_BODY_OUT"
if bash "$CREATE" --title T --start 2026-09-28 --tz America/New_York >/dev/null 2>&1 \
  && ! grep -q timeZone "$STUB_BODY_OUT"; then ok
else bad "--tz is ignored for all-day" "no timeZone key in body" "$(cat "$STUB_BODY_OUT" 2>/dev/null)"; fi

# --- timed --------------------------------------------------------------------

assert_bounds "timed event gets seconds appended" \
  '{"end":{"dateTime":"2026-09-28T10:00:00"},"start":{"dateTime":"2026-09-28T09:00:00"}}' \
  --title T --start 2026-09-28T09:00 --end 2026-09-28T10:00

assert_bounds "timed event keeps an explicit offset" \
  '{"end":{"dateTime":"2026-09-28T10:00:00-04:00"},"start":{"dateTime":"2026-09-28T09:00:00-04:00"}}' \
  --title T --start 2026-09-28T09:00-04:00 --end 2026-09-28T10:00-04:00

assert_bounds "timed event carries timeZone when --tz given" \
  '{"end":{"dateTime":"2026-09-28T10:00:00","timeZone":"America/New_York"},"start":{"dateTime":"2026-09-28T09:00:00","timeZone":"America/New_York"}}' \
  --title T --start 2026-09-28T09:00 --end 2026-09-28T10:00 --tz America/New_York

# --- rejections ---------------------------------------------------------------

assert_rejects "end equal to start is rejected with the exclusivity hint" \
  "EXCLUSIVE" --title T --start 2026-09-28 --end 2026-09-28

assert_rejects "end before start is rejected" \
  "EXCLUSIVE" --title T --start 2026-09-28 --end 2026-09-27

assert_rejects "mixed timed start / date-only end is rejected" \
  "mixed date/dateTime" --title T --start 2026-09-28T09:00 --end 2026-09-29

assert_rejects "--all-day with a timed start is rejected" \
  "date-only --start" --title T --all-day --start 2026-09-28T09:00

assert_rejects "--through and --end together are rejected" \
  "not both" --title T --start 2026-09-28 --through 2026-09-30 --end 2026-10-05

assert_rejects "timed event still requires --end" \
  "required for a timed event" --title T --start 2026-09-28T09:00

assert_rejects "--title is still required" \
  "required" --start 2026-09-28

assert_rejects "malformed --through is rejected" \
  "--through must be a date" --title T --start 2026-09-28 --through "next tuesday"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
