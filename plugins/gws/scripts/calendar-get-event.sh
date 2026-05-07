#!/usr/bin/env bash
# Get a single Google Calendar event by id, or fuzzy-match by title
# within a window if --match is used.
# Usage:
#   calendar-get-event.sh <event-id> [--calendar=ID] [--json] [--tz=IANA]
#   calendar-get-event.sh --match "title fragment" [--from=SPEC] [--to=SPEC]
#                         [--calendar=ID] [--json] [--tz=IANA]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

CALENDAR="primary"
JSON=false
TZ_OUT=""
EVENT_ID=""
MATCH=""
FROM="today"
TO="+7d"

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
    --tz=*)       TZ_OUT="${1#*=}"; shift ;;
    --tz)         TZ_OUT="$2"; shift 2 ;;
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

SELF_EMAIL="$(bash "$SCRIPT_DIR/account-current.sh" --email 2>/dev/null || echo '')"

FMT_ARGS=(--mode get)
[[ "$JSON" == true ]] && FMT_ARGS+=(--json)
[[ -n "$SELF_EMAIL" ]] && FMT_ARGS+=(--self "$SELF_EMAIL")
[[ -n "$TZ_OUT" ]] && FMT_ARGS+=(--tz "$TZ_OUT")

if [[ -n "$EVENT_ID" ]]; then
  RAW="$(gws calendar events get \
    --params "{\"calendarId\":\"$CALENDAR\",\"eventId\":\"$EVENT_ID\"}" 2>/dev/null)"
  printf '%s' "$RAW" | python3 "$SCRIPT_DIR/calendar-format.py" "${FMT_ARGS[@]}"
  exit 0
fi

if [[ -z "$MATCH" ]]; then
  echo "ERROR: provide an event id or --match \"title\"" >&2
  exit 1
fi

TIME_MIN="$(calendar_resolve_date "$FROM" start)"
TIME_MAX="$(calendar_resolve_date "$TO" end)"

PARAMS=$(python3 -c "
import json
print(json.dumps({
  'calendarId': '$CALENDAR',
  'timeMin': '$TIME_MIN',
  'timeMax': '$TIME_MAX',
  'singleEvents': True,
  'orderBy': 'startTime',
  'q': '''$MATCH''',
  'maxResults': 50,
}))
")

RAW="$(gws calendar events list --params "$PARAMS" 2>/dev/null)"

# Pick the first match (q already filters server-side); fall back to a local
# case-insensitive substring match if q returned multiple to find the closest.
BEST="$(printf '%s' "$RAW" | python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('items', [])
needle = '''$MATCH'''.lower()
exact = [e for e in items if needle in (e.get('summary') or '').lower()]
chosen = exact[0] if exact else (items[0] if items else None)
if not chosen:
    sys.exit(2)
print(json.dumps(chosen))
")" || { echo "ERROR: no event matched '$MATCH' in window $FROM..$TO" >&2; exit 1; }

printf '%s' "$BEST" | python3 "$SCRIPT_DIR/calendar-format.py" "${FMT_ARGS[@]}"
