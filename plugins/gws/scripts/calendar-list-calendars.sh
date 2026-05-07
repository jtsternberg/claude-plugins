#!/usr/bin/env bash
# List all calendars accessible to the active gws account.
# Usage: calendar-list-calendars.sh [--json] [--writable]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

JSON=false
WRITABLE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --writable) WRITABLE=true; shift ;;
    -h|--help) sed -n '2,3p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
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
