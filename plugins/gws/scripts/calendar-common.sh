#!/usr/bin/env bash
# Shared helpers for gws calendar-* scripts.
# Source this file; do not execute directly.

# Resolve active gws account config dir if not already set.
_calendar_resolve_account() {
  if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
    local _common
    _common="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/account-common.sh"
    if [[ -f "$_common" ]]; then
      # shellcheck source=/dev/null
      source "$_common"
      export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
    fi
  fi
}

# Convert a fuzzy date spec to an RFC3339 timestamp in local TZ.
# Args: <spec> <bound>
#   spec  = today | tomorrow | yesterday | YYYY-MM-DD | +Nd | -Nd | +Nw
#   bound = start | end   (start = 00:00:00, end = next-day 00:00:00)
# Prints the RFC3339 timestamp on stdout.
calendar_resolve_date() {
  local spec="$1"
  local bound="$2"
  python3 - "$spec" "$bound" <<'PY'
import sys, re
from datetime import datetime, timedelta, time
try:
    from zoneinfo import ZoneInfo
    import time as _time
    tz = ZoneInfo(_time.tzname[0]) if False else None
except Exception:
    tz = None
# Use system local time; astimezone() with no arg uses local.
spec, bound = sys.argv[1], sys.argv[2]
now = datetime.now().astimezone()
local_tz = now.tzinfo
today = datetime.combine(now.date(), time.min, tzinfo=local_tz)

def parse(s):
    s = s.strip().lower()
    if s == "today":    return today
    if s == "tomorrow": return today + timedelta(days=1)
    if s == "yesterday":return today - timedelta(days=1)
    m = re.match(r'^([+-])(\d+)([dwm])$', s)
    if m:
        sign = 1 if m.group(1) == '+' else -1
        n = int(m.group(2)) * sign
        unit = m.group(3)
        if unit == 'd': return today + timedelta(days=n)
        if unit == 'w': return today + timedelta(weeks=n)
        if unit == 'm': return today + timedelta(days=30*n)
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})$', s)
    if m:
        return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)),
                        tzinfo=local_tz)
    raise SystemExit(f"unrecognized date: {s}")

dt = parse(spec)
if bound == "end":
    dt = dt + timedelta(days=1)
print(dt.isoformat())
PY
}

# Strip the "Using keyring backend: keyring" stderr noise — gws emits it on
# every call. Redirect stderr around gws calls if you want clean output.
calendar_gws() {
  gws "$@"
}
