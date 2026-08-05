#!/usr/bin/env bash
# Create a Google Calendar event, optionally with attendees and a Meet link.
# Usage:
#   Timed:   calendar-create-event.sh --title "Title" --start "2026-05-08T14:00"
#                            --end "2026-05-08T15:00"
#                            [--calendar=ID] [--description=TEXT]
#                            [--attendees=a@x.com,b@y.com] [--location=TEXT]
#                            [--meet] [--tz=IANA] [--json]
#   All-day: calendar-create-event.sh --title "Title" --start 2026-09-28
#                            [--through 2026-09-30 | --end 2026-10-01]
#                            [same optional flags; --tz is ignored]
#
# Date-only --start (YYYY-MM-DD) creates an all-day event; no flag needed.
# --end is the API's EXCLUSIVE end date. --through is the inclusive last day
# (a friendlier way to say the same thing). With neither, the event is one day.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

CALENDAR="primary"
TITLE=""
START=""
END=""
THROUGH=""
DESC=""
ATTENDEES=""
LOCATION=""
MEET=false
TZ_IN=""
JSON=false
ALL_DAY=false

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
    --through=*)  THROUGH="${1#*=}"; shift ;;
    --through)    THROUGH="$2"; shift 2 ;;
    --all-day)    ALL_DAY=true; shift ;;
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
    -h|--help) sed -n '2,17p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TITLE" || -z "$START" ]]; then
  echo "ERROR: --title and --start are required" >&2
  exit 1
fi

DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

# All-day is implied by a date-only --start or by --through. Google models
# all-day events as {"date": ...} rather than {"dateTime": ...}; mixing the two
# is a guaranteed 400, so decide once here and validate both bounds together.
if [[ "$START" =~ $DATE_RE || -n "$THROUGH" ]]; then
  ALL_DAY=true
fi

if [[ "$ALL_DAY" == true ]]; then
  if [[ ! "$START" =~ $DATE_RE ]]; then
    echo "ERROR: all-day events need a date-only --start (YYYY-MM-DD); got '$START'" >&2
    exit 1
  fi
  if [[ -n "$THROUGH" && -n "$END" ]]; then
    echo "ERROR: pass either --through (inclusive last day) or --end (exclusive), not both" >&2
    exit 1
  fi
  if [[ -n "$THROUGH" && ! "$THROUGH" =~ $DATE_RE ]]; then
    echo "ERROR: --through must be a date (YYYY-MM-DD); got '$THROUGH'" >&2
    exit 1
  fi
  if [[ -n "$END" && ! "$END" =~ $DATE_RE ]]; then
    echo "ERROR: --start is date-only, so --end must be a date too (YYYY-MM-DD); got '$END'" >&2
    exit 1
  fi
  # Resolve the exclusive end date the API wants.
  if [[ -n "$THROUGH" ]]; then
    END="$(python3 -c "
import sys
from datetime import date, timedelta
y,m,d = (int(x) for x in sys.argv[1].split('-'))
print(date(y,m,d) + timedelta(days=1))" "$THROUGH")"
  elif [[ -z "$END" ]]; then
    END="$(python3 -c "
import sys
from datetime import date, timedelta
y,m,d = (int(x) for x in sys.argv[1].split('-'))
print(date(y,m,d) + timedelta(days=1))" "$START")"
  elif [[ ! "$END" > "$START" ]]; then
    # Lexical compare is correct for zero-padded ISO dates.
    echo "ERROR: --end is EXCLUSIVE, so it must be after --start." >&2
    echo "  For a single all-day event on $START, omit --end." >&2
    echo "  For an event through and including $END, use: --through $END" >&2
    exit 1
  fi
elif [[ -z "$END" ]]; then
  echo "ERROR: --end is required for a timed event" >&2
  exit 1
elif [[ "$END" =~ $DATE_RE ]]; then
  echo "ERROR: --start has a time but --end is date-only ('$END')." >&2
  echo "  Google rejects mixed date/dateTime bounds. Give --end a time, or make" >&2
  echo "  --start date-only for an all-day event." >&2
  exit 1
fi

bash "$SCRIPT_DIR/auth-preflight.sh" --quiet || exit 1

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
all_day = '$ALL_DAY' == 'true'

def normalize_rfc3339(dt):
    # Google Calendar events.insert requires full RFC3339 with seconds for timed
    # events. Append ':00' when the seconds component is missing (e.g.
    # 2026-07-02T09:00), preserving any trailing 'Z' or numeric UTC offset.
    # Not called for all-day events — those carry bare YYYY-MM-DD dates, which
    # the caller has already validated and which go into 'date', not 'dateTime'.
    if not dt:
        return dt
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(:\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?\$', dt)
    if not m:
        return dt
    base, secs, off = m.group(1), m.group(2), m.group(3)
    return base + (secs or ':00') + (off or '')

body = {'summary': title}
if desc: body['description'] = desc
if loc:  body['location'] = loc

if all_day:
    # All-day events use 'date' and carry no timeZone; 'end' is exclusive.
    s = {'date': start}
    e = {'date': end}
else:
    s = {'dateTime': normalize_rfc3339(start)}
    e = {'dateTime': normalize_rfc3339(end)}
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

# Calendar API v3 answers most malformed inserts with a bare
# {"code":400,"message":"Bad Request","reason":"badRequest"} — no field detail,
# from Google, not from gws. Name the likely causes so the caller isn't left
# guessing at an opaque 400.
explain_failure() {
  local blob="$1"
  case "$blob" in
    *400*|*badRequest*)
      {
        echo "  A 400 here is almost always one of:"
        echo "    - a start/end shape the API rejects (all-day needs date-only bounds;"
        echo "      timed needs full RFC3339 — this script normalizes both, so suspect"
        echo "      any values you passed through --params instead)"
        echo "    - --meet on a calendar that cannot host conferences"
        echo "    - attendees on a calendar you only have 'reader' access to"
        echo "  Check your access: calendar-list-calendars.sh --id '$CALENDAR'"
      } >&2 ;;
    *403*|*forbidden*)
      echo "  403 means the account lacks write access to '$CALENDAR'." >&2
      echo "  Check with: calendar-list-calendars.sh --id '$CALENDAR'" >&2 ;;
    *404*|*notFound*)
      echo "  404 means calendar '$CALENDAR' is not visible to this account." >&2
      echo "  List what is: calendar-list-calendars.sh" >&2 ;;
  esac
}

if ! RAW="$(gws calendar events insert --params "$PARAMS_JSON" --json "$BODY" 2>"$ERR_FILE")"; then
  echo "ERROR: calendar events insert failed" >&2
  [[ -s "$ERR_FILE" ]] && cat "$ERR_FILE" >&2
  [[ -n "$RAW" ]] && printf '%s\n' "$RAW" >&2
  explain_failure "$(cat "$ERR_FILE" 2>/dev/null)${RAW:-}"
  echo "  Request body was: $BODY" >&2
  exit 1
fi

# gws can exit 0 yet return an API error object in the body; surface it too.
if printf '%s' "$RAW" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d,dict) and 'error' in d else 1)"; then
  echo "ERROR: calendar events insert returned an API error" >&2
  printf '%s\n' "$RAW" >&2
  explain_failure "$RAW"
  echo "  Request body was: $BODY" >&2
  exit 1
fi

SELF_EMAIL="$(bash "$SCRIPT_DIR/account-current.sh" --email 2>/dev/null || echo '')"
FMT_ARGS=(--mode get)
[[ "$JSON" == true ]] && FMT_ARGS+=(--json)
[[ -n "$SELF_EMAIL" ]] && FMT_ARGS+=(--self "$SELF_EMAIL")

printf '%s' "$RAW" | python3 "$SCRIPT_DIR/calendar-format.py" "${FMT_ARGS[@]}"
