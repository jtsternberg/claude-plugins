---
name: gws-calendar
description: "Google Calendar via the gws CLI — 'what's on my calendar', today's meetings, schedule, find an event, pull its Meet/Zoom link, create events, list calendars."
when_to_use: |
  Use whenever the user asks about their Google Calendar — listing events,
  looking up a single meeting, extracting Meet/Zoom links, listing accessible
  calendars, or creating an event. Respects the active gws account set by
  the gws-account skill.
  Also 'list events tomorrow', 'find my next meeting with X', 'what's the zoom link for my coaching session'. Use instead of constructing raw `gws calendar events list` invocations.
argument-hint: "<list|get|links|calendars|create> [flags]"
allowed-tools: 'Bash(bash *) Bash(gws *) Bash(python3 *)'
---

# Google Calendar (gws)

Query and manage Google Calendar events through the `gws` CLI. All
operations use the currently active gws account
(`~/.config/gws-accounts/.active` — managed by the gws-account skill).

## Prerequisites

```!
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/auth-preflight.sh"
```

Trust this over a hand-rolled `gws auth status` check. `gws` prints
`Using keyring backend: keyring` to **stderr on every call**, so the older
`gws auth status 2>&1 | python3 -c '...json.load...'` form always hit a parse
error and reported `NOT AUTHENTICATED` for perfectly good accounts. The script
also distinguishes "no account selected" from "no credentials" — different
problems with different fixes.

## Task

Parse the user's request and run the matching script. All scripts live in
`plugins/gws/scripts/calendar-*.sh`. Default human-readable output; pass
`--json` for programmatic output.

### List events (default subcommand)

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/calendar-list-events.sh" \
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
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/calendar-get-event.sh" <event-id> \
  [--calendar=ID] [--json] [--tz=IANA]
```

By fuzzy title match within a window (default: today through +7 days):

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/calendar-get-event.sh" \
  --match "title fragment" [--from=SPEC] [--to=SPEC] [--json]
```

Surfaces the specific instance of a recurring event, not the series id.

### Extract Meet / Zoom links (most common ask)

When the user asks "what's the link for X" or "get the meet/zoom link":

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
# Today's links
bash "$PLUGIN_ROOT/scripts/calendar-links.sh"

# Links for matching events in a window
bash "$PLUGIN_ROOT/scripts/calendar-links.sh" \
  --match "coaching" [--from=today --to=+3d]

# Links for a single event by id
bash "$PLUGIN_ROOT/scripts/calendar-links.sh" <event-id>
```

Detects:
- Google Meet via `hangoutLink`
- Zoom via regex against `location` and `description` (includes passcode if present)
- Other video conferences via `conferenceData.entryPoints`

If an event has no conference link, the output says so explicitly — never
silently omit.

### List accessible calendars

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/calendar-list-calendars.sh" \
  [--writable] [--json]
```

Marks the primary calendar with `★`. Use `--writable` to filter to
calendars the active account can write to (owner/writer roles).

### Check access to one calendar

Before writing to a shared or group calendar, check the role directly instead
of listing everything:

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/calendar-list-calendars.sh" \
  --id "<calendarId>" [--json]
```

Prints `[accessRole] Summary (writable | READ-ONLY)`. Exits 1 with an
explanation when the calendar isn't in the account's calendar list — usually
"shared with a different account", not "doesn't exist".

### Create an event (optional)

Timed event:

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/calendar-create-event.sh" \
  --title "Title" --start "2026-05-08T14:00" --end "2026-05-08T15:00" \
  [--calendar=ID] [--description=TEXT] [--location=TEXT] \
  [--attendees=a@x.com,b@y.com] [--meet] [--tz=America/New_York] [--json]
```

All-day event — pass **date-only** `--start` (no `--all-day` flag needed,
though it exists for explicitness):

```bash
# Single day
... --title "Offsite" --start 2026-09-28

# Multi-day, inclusive last day (the human way)
... --title "Conference" --start 2026-09-28 --through 2026-09-30

# Multi-day, exclusive end (what the API itself takes)
... --title "Conference" --start 2026-09-28 --end 2026-10-01
```

All-day and timed bounds cannot be mixed — Google rejects a `date` start with
a `dateTime` end, and the script refuses it up front rather than letting the
API return an opaque 400. `--tz` is ignored for all-day events (they carry no
timezone by design). Google's `end` is **exclusive**; `--through` exists so you
don't have to remember that.

`--meet` auto-generates a Google Meet link. When `--attendees` is set, the
event is sent with `sendUpdates=all`. Confirm with the user before running
this — event creation is a write operation.

### When the helper can't express what you need

The scripts cover the common cases; `gws` reaches the whole API. For anything
they don't model — recurrence (`RRULE`), reminder overrides, extended
properties, guest permissions, transparency/visibility — build the body
yourself and call the CLI directly:

```bash
gws calendar events insert \
  --params '{"calendarId":"<id>"}' \
  --json '{"summary":"...","start":{"date":"2026-09-28"},"end":{"date":"2026-09-29"},
           "recurrence":["RRULE:FREQ=WEEKLY;COUNT=4"]}'
```

`gws calendar --help` and `gws calendar events --help` list every subcommand.

Expect malformed bodies to come back as a bare
`{"code":400,"message":"Bad Request","reason":"badRequest"}` with no field
detail. Nothing surfaces more: `GOOGLE_WORKSPACE_CLI_LOG=gws=trace` and
`GOOGLE_WORKSPACE_CLI_LOG_FILE` both log the same reduced object, so re-read
your body shape rather than hunting for a better message. (Whether Google sent
richer detail that gws dropped is untested — a raw-token comparison against the
REST endpoint would settle it.)

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

- **No active account vs. not authenticated.** Two different problems.
  `auth-preflight.sh` names which one it is: no `.active` file with other
  authed accounts present means *select* one (`account-switch.sh <label>`),
  not re-run OAuth. It also warns when calls are silently going to the
  default config because nothing is selected — the usual cause of "I created
  that event on the wrong account."
- **Recurring events.** List output surfaces the specific instance id
  (`<series>_<UTC-stamp>`), not the series. Use that instance id with
  `calendar-get-event.sh`.
- **Declined events.** Flagged with `[DECLINED]`, never silently filtered.
  If the user explicitly wants to skip declined events, parse the
  `--json` output and filter on the `declined` field.
- **Events with no conference link.** Output says `(no conference link)`
  so it's obvious why a link wasn't returned.
- **Deleted events still resolve by id.** `events.get` returns a deleted event
  with `status: "cancelled"` rather than a 404, so a `get` after a delete looks
  like the delete failed. Output flags these `[CANCELLED]` (`cancelled: true`
  in `--json`). To confirm a deletion, check that flag — not the absence of
  output. A second `delete` on the same id returns `410 deleted`, which is also
  confirmation, not an error to fix.
- **`gws calendar events delete` writes a stray `download.html`.** The API
  answers with `204 No Content`; gws treats the empty body as a download and
  saves it into the current working directory, reporting
  `{"saved_file": "download.html", "status": "success"}`. The delete itself
  works. Remove the file afterward, or `cd` somewhere disposable first.
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
