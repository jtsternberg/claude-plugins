#!/usr/bin/env bash
# List calendars accessible to the active gws account, or check access to one.
# Usage: calendar-list-calendars.sh [--json] [--writable]
#        calendar-list-calendars.sh --id <calendarId> [--json]
#
# --id answers "what is my accessRole on this one calendar?" without listing
# every calendar. Exits 1 if the calendar is not in the account's calendar list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

JSON=false
WRITABLE=false
CAL_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --writable) WRITABLE=true; shift ;;
    --id=*) CAL_ID="${1#*=}"; shift ;;
    --id)   CAL_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

bash "$SCRIPT_DIR/auth-preflight.sh" --quiet || exit 1

if [[ -n "$CAL_ID" ]]; then
  ONE="$(gws calendar calendarList get --params "{\"calendarId\":\"$CAL_ID\"}" 2>/dev/null || true)"
  GWS_ONE="$ONE" GWS_ID="$CAL_ID" JSON="$JSON" python3 <<'PY' || exit 1
import json, os, sys
raw = (os.environ.get('GWS_ONE') or '').strip()
cal_id = os.environ['GWS_ID']
want_json = os.environ['JSON'] == 'true'
try:
    d = json.loads(raw)
except Exception:
    print(f"ERROR: no calendarList entry for '{cal_id}' — the account cannot see it.",
          file=sys.stderr)
    print("  Calendars it can see: calendar-list-calendars.sh", file=sys.stderr)
    sys.exit(1)
if 'error' in d:
    err = d['error']
    print(f"ERROR: {err.get('code','?')} {err.get('message','')} for calendar '{cal_id}'",
          file=sys.stderr)
    if str(err.get('code')) == '404':
        print("  Not in this account's calendar list. It may exist but not be shared,",
              file=sys.stderr)
        print("  or be shared with a different account. List visible ones with:",
              file=sys.stderr)
        print("    calendar-list-calendars.sh", file=sys.stderr)
    sys.exit(1)
row = {
    'id': d.get('id'),
    'summary': d.get('summary'),
    'primary': bool(d.get('primary')),
    'accessRole': d.get('accessRole', ''),
    'timeZone': d.get('timeZone'),
    'writable': d.get('accessRole') in ('owner', 'writer'),
}
if want_json:
    print(json.dumps(row, indent=2))
else:
    verdict = 'writable' if row['writable'] else 'READ-ONLY'
    print(f"[{row['accessRole']}] {row['summary']}  ({verdict})")
    print(f"    {row['id']}")
PY
  exit 0
fi

RAW="$(gws calendar calendarList list --params '{"maxResults":250}' 2>/dev/null)"

GWS_CAL_RAW="$RAW" JSON="$JSON" WRITABLE="$WRITABLE" python3 <<'PY'
import json, os
want_json = os.environ['JSON'] == 'true'
writable_only = os.environ['WRITABLE'] == 'true'
WRITE_ROLES = {'owner', 'writer'}
data = json.loads(os.environ['GWS_CAL_RAW'])
items = data.get('items', [])
rows = []
for c in items:
    role = c.get('accessRole', '')
    if writable_only and role not in WRITE_ROLES:
        continue
    rows.append({
        'id': c.get('id'),
        'summary': c.get('summary'),
        'primary': bool(c.get('primary')),
        'accessRole': role,
        'timeZone': c.get('timeZone'),
    })
if want_json:
    print(json.dumps(rows, indent=2))
else:
    for r in rows:
        marker = '★' if r['primary'] else ' '
        print(f"{marker} [{r['accessRole']:<8}] {r['summary']}")
        print(f"    {r['id']}")
PY
