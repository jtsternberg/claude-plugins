# GWS (Google Workspace CLI)

A Claude Code plugin for interacting with Google Workspace via the official [`gws`](https://github.com/googleworkspace/cli) CLI — starting with uploading markdown files to Google Drive as formatted Google Docs.

## Skills

### md-to-google-doc

Upload a local markdown file to Google Drive as a Google Doc, or update an existing one. Handles:

- YAML frontmatter stripping
- Obsidian callout cleanup (`> [!NOTE]` etc.)
- Auto-derived title from the first `# H1` heading (or filename)
- Pageless document format
- Create-vs-update auto-detection (folder ID = create, doc URL = update)

#### Usage

```bash
# Create a new Google Doc in a Drive folder
/md-to-google-doc ./notes.md FOLDER_ID

# With a custom title
/md-to-google-doc ./notes.md FOLDER_ID --title "My Document"

# Update an existing Google Doc
/md-to-google-doc ./notes.md "https://docs.google.com/document/d/DOC_ID/edit"
```

The folder ID is the last segment of a Drive folder URL:
`https://drive.google.com/drive/u/0/folders/FOLDER_ID_HERE`

### google-doc-to-md

Download a Google Doc as a local markdown file using the Drive API's native `text/markdown` export.

```bash
/google-doc-to-md DOC_ID_OR_URL [output.md] [--title]
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

### gmail-read

Search Gmail and read messages for the active account. Runs a Gmail search
query and returns structured results (id, subject, from, date, snippet), and
optionally full message bodies with HTML stripped to plain text.

```bash
bash plugins/gws/skills/gmail-read/scripts/read.sh "from:boss@example.com newer_than:7d"
```

### gmail-draft-from-markdown

Convert a local markdown file into a Gmail **draft** (never sends). Markdown is
converted to HTML and saved as a draft; you review and send from Gmail's UI.

```bash
bash plugins/gws/skills/gmail-draft-from-markdown/scripts/draft.sh ./reply.md \
  someone@example.com --subject "Follow-up"
```

### youtube

Manage YouTube playlists for the active account: list playlists, list items,
add/remove items, cleanup. See `skills/youtube/SKILL.md` for the full command
set. YouTube uses its own OAuth login (`youtube-login.sh`) separate from the
core Google Workspace scopes.

## Prerequisites

- `gws` CLI installed and on `$PATH`
- An OAuth client (`client_secret.json`) in place and an authenticated account (see **Accounts & Authentication** below)

Check auth status with `gws auth status`.

## Accounts & Authentication

`gws` authenticates with a Google OAuth **"installed app"** client
(`client_secret.json`) that you supply — created in a Google Cloud project that
has the Workspace APIs you need enabled (Drive, Docs, Sheets, Gmail, Calendar,
Slides, Tasks). The same client can authenticate any account allowed by its
OAuth consent screen.

**Single account (default).** Put the client at `~/.config/gws/client_secret.json`,
then `gws auth login` and pick the account in the browser. All state (encrypted
credentials, token cache) lives in `~/.config/gws/`.

**Multiple accounts.** The `gws-account` skill manages additional accounts, each
in its own config directory under `~/.config/gws-accounts/<label>/` with its own
`client_secret.json`, credentials, and token. Switching writes the chosen label
to `~/.config/gws-accounts/.active`, which every account-aware script respects
across shell sessions and agent invocations.

```bash
/gws-account add work        # browser OAuth into a new labeled account
/gws-account switch work     # make 'work' the active account
/gws-account switch default  # back to ~/.config/gws
/gws-account current         # show the active account
```

> Different accounts can use different OAuth clients. `gws-account add` copies
> the **default** client into the new account dir; if a given account needs a
> *different* client (e.g. an org-internal OAuth app for a managed Workspace
> domain), place that account's `client_secret.json` into its
> `~/.config/gws-accounts/<label>/` dir **before** logging in, rather than using
> `add` (which would overwrite it with the default client). Then log in with
> `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=~/.config/gws-accounts/<label> gws auth login`.

**Re-authenticating.** If a token expires (`invalid_grant` / `invalid_rapt` /
"Authentication expired"), re-run `gws auth login` for the affected account
(prefix with `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=…` for a labeled account).

## Install

```bash
claude plugins add /path/to/claude-plugins/plugins/gws
```

## What's Included

| File | Purpose |
|------|---------|
| `skills/md-to-google-doc/SKILL.md` | Skill definition — triggers, usage, troubleshooting |
| `scripts/gdoc.sh` | Router: auto-detects create vs update |
| `scripts/upload.sh` | Creates a new Google Doc from markdown |
| `scripts/update.sh` | Updates an existing Google Doc from markdown |
| `scripts/clean.sh` | Strips YAML frontmatter and Obsidian callouts |
| `references/MANUAL.md` | Step-by-step fallback if scripts are unavailable |
| `skills/google-doc-to-md/SKILL.md` | Download a Google Doc as markdown |
| `skills/account/SKILL.md` | Multi-account management for the `gws` CLI |
| `skills/calendar/SKILL.md` | Calendar events, meet/zoom links, calendar listing |
| `skills/gmail-read/SKILL.md` | Search Gmail and read messages (headers, snippet, plain-text body) |
| `skills/gmail-draft-from-markdown/SKILL.md` | Create Gmail drafts from markdown (never sends) |
| `skills/youtube/SKILL.md` | YouTube playlist management (list, add/remove, cleanup) |
| `scripts/calendar-list-events.sh` | List events in a date range |
| `scripts/calendar-get-event.sh` | Get a single event by id or fuzzy match |
| `scripts/calendar-links.sh` | Extract Meet/Zoom links for events |
| `scripts/calendar-list-calendars.sh` | List accessible calendars |
| `scripts/calendar-create-event.sh` | Create a calendar event (optional Meet link) |

## Disclaimer

This plugin wraps the third-party open-source [`gws`](https://github.com/googleworkspace/cli)
CLI (Apache-2.0). Per its own README:

> ⚠️ This is **not** an officially supported Google product.

It's provided as-is, with no warranty.
