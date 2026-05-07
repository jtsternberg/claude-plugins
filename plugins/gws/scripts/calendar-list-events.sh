#!/usr/bin/env bash
# List Google Calendar events in a date range.
# Usage: calendar-list-events.sh [--calendar=ID] [--query=TEXT]
#                                [--from=SPEC] [--to=SPEC]
#                                [--max=N] [--tz=IANA] [--json]
# Date specs: today | tomorrow | yesterday | YYYY-MM-DD | +Nd | -Nd | +Nw
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/calendar-common.sh"
_calendar_resolve_account

CALENDAR="primary"
QUERY=""
FROM="today"
TO="today"
MAX="250"
TZ_OUT=""
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calendar=*) CALENDAR="${1#*=}"; shift ;;
    --calendar)   CALENDAR="$2"; shift 2 ;;
    --query=*)    QUERY="${1#*=}"; shift ;;
    --query)      QUERY="$2"; shift 2 ;;
    -q)           QUERY="$2"; shift 2 ;;
    --from=*)     FROM="${1#*=}"; shift ;;
    --from)       FROM="$2"; shift 2 ;;
    --to=*)       TO="${1#*=}"; shift ;;
    --to)         TO="$2"; shift 2 ;;
    --max=*)      MAX="${1#*=}"; shift ;;
    --max)        MAX="$2"; shift 2 ;;
    --tz=*)       TZ_OUT="${1#*=}"; shift ;;
    --tz)         TZ_OUT="$2"; shift 2 ;;
    --json)       JSON=true; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  echo "  or switch accounts: bash $SCRIPT_DIR/account-switch.sh <label>" >&2
  exit 1
fi

TIME_MIN="$(calendar_resolve_date "$FROM" start)"
TIME_MAX="$(calendar_resolve_date "$TO" end)"

# Active account email (for declined-event detection)
SELF_EMAIL="$(bash "$SCRIPT_DIR/account-current.sh" --email 2>/dev/null || echo '')"

PARAMS=$(python3 -c "
import json, sys
p = {
  'calendarId': '$CALENDAR',
  'timeMin': '$TIME_MIN',
  'timeMax': '$TIME_MAX',
  'singleEvents': True,
  'orderBy': 'startTime',
  'maxResults': int('$MAX'),
}
q = '''$QUERY'''
if q:
    p['q'] = q
print(json.dumps(p))
")

RAW="$(gws calendar events list --params "$PARAMS" 2>/dev/null)"

FMT_ARGS=(--mode list)
[[ "$JSON" == true ]] && FMT_ARGS+=(--json)
[[ -n "$SELF_EMAIL" ]] && FMT_ARGS+=(--self "$SELF_EMAIL")
[[ -n "$TZ_OUT" ]] && FMT_ARGS+=(--tz "$TZ_OUT")

printf '%s' "$RAW" | python3 "$SCRIPT_DIR/calendar-format.py" "${FMT_ARGS[@]}"
