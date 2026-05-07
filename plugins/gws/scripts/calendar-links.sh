#!/usr/bin/env bash
# Extract conference (Meet / Zoom / video) links for one or more events.
# Usage:
#   calendar-links.sh                      # links for today's events
#   calendar-links.sh --match "coaching"   # links for matching events in window
#   calendar-links.sh <event-id>           # links for a specific event
# Flags: --calendar=ID  --from=SPEC  --to=SPEC  --json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

CALENDAR="primary"
MATCH=""
EVENT_ID=""
FROM="today"
TO="today"
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calendar=*) CALENDAR="${1#*=}"; shift ;;
    --calendar)   CALENDAR="$2"; shift 2 ;;
    --match=*)    MATCH="${1#*=}"; shift ;;
    --match)      MATCH="$2"; shift 2 ;;
    --from=*)     FROM="${1#*=}"; shift ;;
    --from)       FROM="$2"; shift 2 ;;
    --to=*)       TO="${1#*=}"; shift ;;
    --to)         TO="$2"; shift 2 ;;
    --json)       JSON=true; shift ;;
    -h|--help) sed -n '2,9p' "$0" >&2; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  EVENT_ID="$1"; shift ;;
  esac
done

if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
fi

if [[ -n "$EVENT_ID" ]]; then
  RAW="$(gws calendar events get \
    --params "{\"calendarId\":\"$CALENDAR\",\"eventId\":\"$EVENT_ID\"}" 2>/dev/null)"
  EVENTS_JSON="{\"items\":[$RAW]}"
else
  TIME_MIN="$(calendar_resolve_date "$FROM" start)"
  TIME_MAX="$(calendar_resolve_date "$TO" end)"
  PARAMS=$(python3 -c "
import json
p = {
  'calendarId': '$CALENDAR',
  'timeMin': '$TIME_MIN', 'timeMax': '$TIME_MAX',
  'singleEvents': True, 'orderBy': 'startTime', 'maxResults': 250,
}
m = '''$MATCH'''
if m:
    p['q'] = m
print(json.dumps(p))
")
  EVENTS_JSON="$(gws calendar events list --params "$PARAMS" 2>/dev/null)"
fi

GWS_CAL_RAW="$EVENTS_JSON" JSON="$JSON" CF_PATH="$SCRIPT_DIR/calendar-format.py" python3 <<'PY'
import json, os, sys, importlib.util
want_json = os.environ['JSON'] == 'true'
spec = importlib.util.spec_from_file_location('cf', os.environ['CF_PATH'])
cf = importlib.util.module_from_spec(spec); spec.loader.exec_module(cf)
data = json.loads(os.environ['GWS_CAL_RAW'])
items = data.get('items', [data]) if isinstance(data, dict) else []
out = []
for e in items:
    links = cf.extract_links(e)
    if not links and not want_json:
        continue
    out.append({
        'id': e.get('id'),
        'summary': e.get('summary'),
        'start': cf.event_start(e),
        'links': links,
    })
if want_json:
    print(json.dumps(out, indent=2))
else:
    if not out:
        print('(no conference links found)')
    for o in out:
        print(f"{o['summary']}")
        for l in o['links']:
            line = f"  {l['url']}"
            if l.get('passcode'):
                line += f"  passcode: {l['passcode']}"
            if l['kind'] != 'meet':
                line += f"  ({l['kind']})"
            print(line)
PY
