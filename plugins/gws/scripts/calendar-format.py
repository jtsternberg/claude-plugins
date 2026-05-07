#!/usr/bin/env python3
"""Format Google Calendar event JSON for human-readable output.

Reads a JSON object on stdin: either a single event, or a list response with
"items". Writes a friendly summary to stdout.

Flags:
  --json       Pass through raw JSON (after normalization).
  --self EMAIL Email of the active account, used to flag declined events.
  --tz TZ      IANA timezone for output (default: local).
"""
import argparse, json, re, sys
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

ZOOM_RE = re.compile(r'https?://[a-z0-9.-]*zoom\.us/(?:j|my|w|meeting)/[^\s)>"\']+', re.I)
PASSCODE_RE = re.compile(r'(?:passcode|password|pwd)[:=\s]+([A-Za-z0-9]+)', re.I)


def extract_links(event):
    """Return list of {kind, url, passcode?} for an event."""
    links = []
    if event.get('hangoutLink'):
        links.append({'kind': 'meet', 'url': event['hangoutLink']})
    # Zoom in location/description
    haystack = ' '.join(filter(None, [event.get('location', ''), event.get('description', '')]))
    seen = {l['url'] for l in links}
    for m in ZOOM_RE.finditer(haystack):
        url = m.group(0).rstrip('.,);')
        if url in seen:
            continue
        seen.add(url)
        entry = {'kind': 'zoom', 'url': url}
        # Look for a passcode within ~150 chars after the URL
        tail = haystack[m.end(): m.end() + 200]
        pm = PASSCODE_RE.search(tail)
        if pm:
            entry['passcode'] = pm.group(1)
        links.append(entry)
    # Generic conferenceData entryPoints (catches non-Meet/Zoom)
    for ep in (event.get('conferenceData', {}) or {}).get('entryPoints', []) or []:
        if ep.get('entryPointType') == 'video' and ep.get('uri'):
            url = ep['uri']
            if url in seen:
                continue
            seen.add(url)
            entry = {'kind': 'video', 'url': url}
            if ep.get('passcode'):
                entry['passcode'] = ep['passcode']
            links.append(entry)
    return links


def event_start(event):
    s = event.get('start') or {}
    return s.get('dateTime') or s.get('date') or ''


def is_declined(event, self_email):
    if not self_email:
        return False
    for a in event.get('attendees', []) or []:
        if a.get('self') and a.get('responseStatus') == 'declined':
            return True
        if a.get('email', '').lower() == self_email.lower() and a.get('responseStatus') == 'declined':
            return True
    return False


def format_time(iso, tz):
    if not iso:
        return ''
    if 'T' not in iso:
        # All-day event
        return iso + ' (all-day)'
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
    except ValueError:
        return iso
    if tz and ZoneInfo:
        try:
            dt = dt.astimezone(ZoneInfo(tz))
        except Exception:
            dt = dt.astimezone()
    else:
        dt = dt.astimezone()
    # Format like "9:00 AM ET — Wed May 7"
    label = dt.strftime('%-I:%M %p').lstrip('0')
    tzname = dt.tzname() or ''
    date_part = dt.strftime('%a %b %-d')
    return f"{label} {tzname} ({date_part})"


def format_event(event, self_email, tz, indent=''):
    title = event.get('summary', '(no title)')
    start = event_start(event)
    when = format_time(start, tz)
    declined = is_declined(event, self_email)
    flag = ' [DECLINED]' if declined else ''
    attendees = event.get('attendees') or []
    n_att = len(attendees)
    lines = []
    head = f"{indent}{when} — {title}{flag}"
    if n_att:
        head += f"  ({n_att} attendee{'s' if n_att != 1 else ''})"
    lines.append(head)
    links = extract_links(event)
    if links:
        for l in links:
            line = f"{indent}  {l['url']}"
            if l.get('passcode'):
                line += f"  passcode: {l['passcode']}"
            if l['kind'] != 'meet':
                line += f"  ({l['kind']})"
            lines.append(line)
    elif event.get('location'):
        lines.append(f"{indent}  📍 {event['location']}")
    else:
        lines.append(f"{indent}  (no conference link)")
    if event.get('id'):
        lines.append(f"{indent}  id: {event['id']}")
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--self', default='', help='Active account email for declined detection')
    ap.add_argument('--tz', default='', help='IANA timezone for time output')
    ap.add_argument('--mode', default='list', choices=['list', 'get'])
    args = ap.parse_args()

    raw = sys.stdin.read()
    if not raw.strip():
        print('(no data)', file=sys.stderr)
        sys.exit(1)
    data = json.loads(raw)

    if args.mode == 'get' or 'items' not in data:
        events = [data]
    else:
        events = data.get('items', [])

    if args.json:
        out = []
        for e in events:
            out.append({
                'id': e.get('id'),
                'summary': e.get('summary'),
                'start': event_start(e),
                'end': (e.get('end') or {}).get('dateTime') or (e.get('end') or {}).get('date'),
                'attendees': len(e.get('attendees') or []),
                'declined': is_declined(e, args.self),
                'links': extract_links(e),
                'location': e.get('location'),
                'htmlLink': e.get('htmlLink'),
                'recurringEventId': e.get('recurringEventId'),
            })
        if args.mode == 'get':
            json.dump(out[0] if out else {}, sys.stdout, indent=2)
        else:
            json.dump(out, sys.stdout, indent=2)
        print()
        return

    if not events:
        print('(no events)')
        return
    for e in events:
        print(format_event(e, args.self, args.tz))


if __name__ == '__main__':
    main()
