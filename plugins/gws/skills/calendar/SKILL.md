---
name: gws-calendar
description: Query and manage Google Calendar events via the gws CLI for the currently active gws account. Triggers on "what's on my calendar", "today's meetings", "what's my schedule", "list events tomorrow", "find my next meeting with X", "get the meet link for [event]", "what's the zoom link for my coaching session", "create a calendar event", "list my calendars". Use this skill instead of constructing raw `gws calendar events list` invocations.
when_to_use: |
  Use whenever the user asks about their Google Calendar — listing events,
  looking up a single meeting, extracting Meet/Zoom links, listing accessible
  calendars, or creating an event. Respects the active gws account set by
  the gws-account skill.
argument-hint: <list|get|links|calendars|create> [flags]
allowed-tools: 'Bash(bash *) Bash(gws *) Bash(python3 *)'
---

# Google Calendar (gws)

Query and manage Google Calendar events through the `gws` CLI. All
operations use the currently active gws account
(`~/.config/gws-accounts/.active` — managed by the gws-account skill).

## Prerequisites

```!
gws auth status 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Authenticated as: {d.get(\"user\",\"unknown\")}')" 2>/dev/null || echo "NOT AUTHENTICATED — run: gws auth login"
```

## Task

Parse the user's request and run the matching script. All scripts live in
`plugins/gws/scripts/calendar-*.sh`. Default human-readable output; pass
`--json` for programmatic output.

### List events (default subcommand)

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-list-events.sh \
  [--calendar=ID] [--query=TEXT] \
  [--from=SPEC] [--to=SPEC] [--max=N] [--tz=IANA] [--json]
```

Date specs: `today` | `tomorrow` | `yesterday` | `YYYY-MM-DD` | `+Nd` | `-Nd` | `+Nw`.

Defaults: `--calendar=primary`, `--from=today`, `--to=today`,
`--max=250`. Always uses `singleEvents=true&orderBy=startTime`.

Examples:
- "what's on my calendar today" → no flags needed
- "tomorrow's meetings" → `--from=tomorrow --to=tomorrow`
- "this week" → `--from=today --to=+7d`
- "coaching sessions today" → `--query="coaching"`

### Get a single event

By id:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-get-event.sh <event-id> \
  [--calendar=ID] [--json] [--tz=IANA]
```

By fuzzy title match within a window (default: today through +7 days):

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-get-event.sh \
  --match "title fragment" [--from=SPEC] [--to=SPEC] [--json]
```

Surfaces the specific instance of a recurring event, not the series id.

### Extract Meet / Zoom links (most common ask)

When the user asks "what's the link for X" or "get the meet/zoom link":

```bash
# Today's links
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-links.sh

# Links for matching events in a window
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-links.sh \
  --match "coaching" [--from=today --to=+3d]

# Links for a single event by id
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-links.sh <event-id>
```

Detects:
- Google Meet via `hangoutLink`
- Zoom via regex against `location` and `description` (includes passcode if present)
- Other video conferences via `conferenceData.entryPoints`

If an event has no conference link, the output says so explicitly — never
silently omit.

### List accessible calendars

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-list-calendars.sh \
  [--writable] [--json]
```

Marks the primary calendar with `★`. Use `--writable` to filter to
calendars the active account can write to (owner/writer roles).

### Create an event (optional)

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/calendar-create-event.sh \
  --title "Title" --start "2026-05-08T14:00" --end "2026-05-08T15:00" \
  [--calendar=ID] [--description=TEXT] [--location=TEXT] \
  [--attendees=a@x.com,b@y.com] [--meet] [--tz=America/New_York] [--json]
```

`--meet` auto-generates a Google Meet link. When `--attendees` is set, the
event is sent with `sendUpdates=all`. Confirm with the user before running
this — event creation is a write operation.

## Example output

For "what are my coaching links today?":

```
9:00 AM EDT (Thu May 7) — Nathalie <> Justin : Coaching  (2 attendees)
  https://meet.google.com/ppb-uhmk-vos
11:00 AM EDT (Thu May 7) — Co-Coaching Session - Justin, Diana, Sam, Tonya  (4 attendees)
  https://meet.google.com/htd-vett-kfd
12:00 PM EDT (Thu May 7) — PQ Growth Collective  (15 attendees)
  https://us06web.zoom.us/j/81182789025?pwd=...  passcode: ...  (zoom)
```

Declined events are flagged inline with `[DECLINED]` rather than hidden,
so the user can decide whether to attend.

## Edge cases

- **No active account / not authenticated.** The script exits with an
  instruction to run `gws auth login` or to switch accounts via the
  gws-account skill.
- **Recurring events.** List output surfaces the specific instance id
  (`<series>_<UTC-stamp>`), not the series. Use that instance id with
  `calendar-get-event.sh`.
- **Declined events.** Flagged with `[DECLINED]`, never silently filtered.
  If the user explicitly wants to skip declined events, parse the
  `--json` output and filter on the `declined` field.
- **Events with no conference link.** Output says `(no conference link)`
  so it's obvious why a link wasn't returned.
- **Different account needed.** If the calendar belongs to another
  Google account, switch first via the gws-account skill, then re-run.

## How it works

- Active account is resolved via `account-common.sh::resolve_active_config`
  and exported as `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` so `gws` picks it up.
- All list calls pass `singleEvents=true` and `orderBy=startTime` for
  predictable, instance-level output.
- Times are rendered in the local TZ by default; override with `--tz`.
- Conference link extraction lives in `calendar-format.py::extract_links`
  and is shared across `list-events`, `get-event`, and `links` for
  consistent detection.
