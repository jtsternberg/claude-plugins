# GWS (Google Workspace CLI)

A Claude Code plugin for interacting with Google Workspace via the [`gws`](https://github.com/nicholasgasior/gws) CLI — starting with uploading markdown files to Google Drive as formatted Google Docs.

## Skills

### md-to-gdoc

Upload a local markdown file to Google Drive as a Google Doc, or update an existing one. Handles:

- YAML frontmatter stripping
- Obsidian callout cleanup (`> [!NOTE]` etc.)
- Auto-derived title from the first `# H1` heading (or filename)
- Pageless document format
- Create-vs-update auto-detection (folder ID = create, doc URL = update)

#### Usage

```bash
# Create a new Google Doc in a Drive folder
/md-to-gdoc ./notes.md FOLDER_ID

# With a custom title
/md-to-gdoc ./notes.md FOLDER_ID --title "My Document"

# Update an existing Google Doc
/md-to-gdoc ./notes.md "https://docs.google.com/document/d/DOC_ID/edit"
```

The folder ID is the last segment of a Drive folder URL:
`https://drive.google.com/drive/u/0/folders/FOLDER_ID_HERE`

### gdoc-to-md

Download a Google Doc as a local markdown file using the Drive API's native `text/markdown` export.

```bash
/gdoc-to-md DOC_ID_OR_URL [output.md] [--title]
```

### gws-account

Manage multiple Google accounts for the `gws` CLI. Each account lives in its own config directory under `~/.config/gws-accounts/<label>/`.

```bash
/gws-account add <label>      # Add account (browser OAuth)
/gws-account list             # List accounts
/gws-account switch <label>   # Switch active account
/gws-account current          # Show active account
```

### gws-calendar

Query and manage Google Calendar events for the active account: list events, look up a single meeting, extract Meet/Zoom links, list calendars, create events.

```bash
# List today's events
bash plugins/gws/scripts/calendar-list-events.sh

# Tomorrow's events
bash plugins/gws/scripts/calendar-list-events.sh --from=tomorrow --to=tomorrow

# Just the conference links for today
bash plugins/gws/scripts/calendar-links.sh

# Find a specific event
bash plugins/gws/scripts/calendar-get-event.sh --match "coaching"

# List accessible calendars (★ = primary)
bash plugins/gws/scripts/calendar-list-calendars.sh

# Create event with auto-generated Meet link
bash plugins/gws/scripts/calendar-create-event.sh \
  --title "Sync" --start "2026-05-08T14:00" --end "2026-05-08T15:00" \
  --attendees "a@x.com,b@y.com" --meet
```

Date specs: `today` | `tomorrow` | `yesterday` | `YYYY-MM-DD` | `+Nd` | `+Nw`. All scripts accept `--json` for programmatic output.

## Prerequisites

- `gws` CLI installed and on `$PATH`
- Authenticated: `gws auth login`

Check auth status with `gws auth status`.

## Install

```bash
claude plugins add /path/to/claude-plugins/plugins/gws
```

## What's Included

| File | Purpose |
|------|---------|
| `skills/md-to-gdoc/SKILL.md` | Skill definition — triggers, usage, troubleshooting |
| `scripts/gdoc.sh` | Router: auto-detects create vs update |
| `scripts/upload.sh` | Creates a new Google Doc from markdown |
| `scripts/update.sh` | Updates an existing Google Doc from markdown |
| `scripts/clean.sh` | Strips YAML frontmatter and Obsidian callouts |
| `references/MANUAL.md` | Step-by-step fallback if scripts are unavailable |
| `skills/gdoc-to-md/SKILL.md` | Download a Google Doc as markdown |
| `skills/account/SKILL.md` | Multi-account management for the `gws` CLI |
| `skills/calendar/SKILL.md` | Calendar events, meet/zoom links, calendar listing |
| `scripts/calendar-list-events.sh` | List events in a date range |
| `scripts/calendar-get-event.sh` | Get a single event by id or fuzzy match |
| `scripts/calendar-links.sh` | Extract Meet/Zoom links for events |
| `scripts/calendar-list-calendars.sh` | List accessible calendars |
| `scripts/calendar-create-event.sh` | Create a calendar event (optional Meet link) |
