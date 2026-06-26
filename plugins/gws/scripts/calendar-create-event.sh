#!/usr/bin/env bash
# Create a Google Calendar event, optionally with attendees and a Meet link.
# Usage:
#   calendar-create-event.sh --title "Title" --start "2026-05-08T14:00"
#                            --end "2026-05-08T15:00"
#                            [--calendar=ID] [--description=TEXT]
#                            [--attendees=a@x.com,b@y.com] [--location=TEXT]
#                            [--meet] [--tz=IANA] [--json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

CALENDAR="primary"
TITLE=""
START=""
END=""
DESC=""
ATTENDEES=""
LOCATION=""
MEET=false
TZ_IN=""
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calendar=*) CALENDAR="${1#*=}"; shift ;;
    --calendar)   CALENDAR="$2"; shift 2 ;;
    --title=*)    TITLE="${1#*=}"; shift ;;
    --title)      TITLE="$2"; shift 2 ;;
    --start=*)    START="${1#*=}"; shift ;;
    --start)      START="$2"; shift 2 ;;
    --end=*)      END="${1#*=}"; shift ;;
    --end)        END="$2"; shift 2 ;;
    --description=*) DESC="${1#*=}"; shift ;;
    --description)   DESC="$2"; shift 2 ;;
    --attendees=*) ATTENDEES="${1#*=}"; shift ;;
    --attendees)   ATTENDEES="$2"; shift 2 ;;
    --location=*) LOCATION="${1#*=}"; shift ;;
    --location)   LOCATION="$2"; shift 2 ;;
    --tz=*)       TZ_IN="${1#*=}"; shift ;;
    --tz)         TZ_IN="$2"; shift 2 ;;
    --meet)       MEET=true; shift ;;
    --json)       JSON=true; shift ;;
    -h|--help) sed -n '2,9p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TITLE" || -z "$START" || -z "$END" ]]; then
  echo "ERROR: --title, --start, and --end are required" >&2
  exit 1
fi

if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
fi

BODY=$(python3 -c "
import json, os, re, uuid, sys
title = '''$TITLE'''
desc  = '''$DESC'''
loc   = '''$LOCATION'''
start = '''$START'''
end   = '''$END'''
tz    = '''$TZ_IN'''
attendees_raw = '''$ATTENDEES'''
meet  = '$MEET' == 'true'

def normalize_rfc3339(dt):
    # Google Calendar events.insert requires full RFC3339 with seconds.
    # Append ':00' when the seconds component is missing (e.g. 2026-07-02T09:00),
    # preserving any trailing 'Z' or numeric UTC offset. Leave unrecognized
    # formats (e.g. date-only all-day values) untouched.
    if not dt:
        return dt
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(:\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?\$', dt)
    if not m:
        return dt
    base, secs, off = m.group(1), m.group(2), m.group(3)
    return base + (secs or ':00') + (off or '')

start = normalize_rfc3339(start)
end   = normalize_rfc3339(end)

body = {'summary': title}
if desc: body['description'] = desc
if loc:  body['location'] = loc

s = {'dateTime': start}
e = {'dateTime': end}
if tz:
    s['timeZone'] = tz; e['timeZone'] = tz
body['start'] = s
body['end'] = e

if attendees_raw:
    body['attendees'] = [{'email': a.strip()} for a in attendees_raw.split(',') if a.strip()]
if meet:
    body['conferenceData'] = {
        'createRequest': {
            'requestId': str(uuid.uuid4()),
            'conferenceSolutionKey': {'type': 'hangoutsMeet'},
        }
    }
print(json.dumps(body))
")

PARAMS_JSON="{\"calendarId\":\"$CALENDAR\""
if [[ "$MEET" == true ]]; then
  PARAMS_JSON="$PARAMS_JSON,\"conferenceDataVersion\":1"
fi
if [[ -n "$ATTENDEES" ]]; then
  PARAMS_JSON="$PARAMS_JSON,\"sendUpdates\":\"all\""
fi
PARAMS_JSON="$PARAMS_JSON}"

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT
if ! RAW="$(gws calendar events insert --params "$PARAMS_JSON" --json "$BODY" 2>"$ERR_FILE")"; then
  echo "ERROR: calendar events insert failed" >&2
  [[ -s "$ERR_FILE" ]] && cat "$ERR_FILE" >&2
  [[ -n "$RAW" ]] && printf '%s\n' "$RAW" >&2
  exit 1
fi

# gws can exit 0 yet return an API error object in the body; surface it too.
if printf '%s' "$RAW" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d,dict) and 'error' in d else 1)"; then
  echo "ERROR: calendar events insert returned an API error" >&2
  printf '%s\n' "$RAW" >&2
  exit 1
fi

SELF_EMAIL="$(bash "$SCRIPT_DIR/account-current.sh" --email 2>/dev/null || echo '')"
FMT_ARGS=(--mode get)
[[ "$JSON" == true ]] && FMT_ARGS+=(--json)
[[ -n "$SELF_EMAIL" ]] && FMT_ARGS+=(--self "$SELF_EMAIL")

printf '%s' "$RAW" | python3 "$SCRIPT_DIR/calendar-format.py" "${FMT_ARGS[@]}"
