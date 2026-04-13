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
