---
name: md-to-gdoc
description: Upload markdown to Google Drive as a Google Doc via gws CLI. Strips frontmatter and Obsidian callouts. Triggers on "upload to google docs", "push to drive", "sync to gdoc", "create a google doc", "gws upload".
argument-hint: [file.md] [folder-id-or-doc-url] [--title "Title"]
allowed-tools: Bash(gws *) Bash(bash *) Bash(python3 *)
---

# Markdown to Google Doc

Upload local markdown files to Google Drive as formatted Google Docs using
the `gws` CLI.

## Prerequisites

```!
gws auth status 2>&1 || echo "NOT AUTHENTICATED — run: gws auth login"
```

## Task

Run the entrypoint script, passing all arguments through. It auto-detects
create vs update based on whether the destination looks like a doc URL/ID
or a folder ID:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/gdoc.sh $ARGUMENTS
```

If no arguments were provided, ask the user for the file path and destination.

Optional flags: `--title "Custom Title"` overrides the auto-derived title.

## Script Details

### Creating a New Google Doc

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file.md FOLDER_ID
```

With a custom title:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file.md FOLDER_ID --title "My Document"
```

The script handles: frontmatter stripping, Obsidian callout cleanup, title
derivation, upload, verification, and temp file cleanup.
It prints the Google Doc URL on success.

**Important:** The `gws` CLI requires `--upload` paths within the current
working directory. The script creates a temp file in cwd automatically, but
the source file must be accessible from cwd (use relative paths or copy first).

### Extracting a Folder ID

The folder ID is the last path segment of a Drive folder URL:
`https://drive.google.com/drive/u/0/folders/FOLDER_ID_HERE`

### Title Derivation

When no `--title` is given, the script:
1. Looks for an `# H1 heading` in the file (after frontmatter)
2. Falls back to the filename with `.md` stripped and hyphens replaced by spaces

### Updating an Existing Google Doc

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update.sh ./file.md DOC_ID
```

Also accepts a full Google Doc URL instead of a bare doc ID:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/update.sh ./file.md "https://docs.google.com/document/d/DOC_ID/edit"
```

## Batch Uploads

When uploading multiple files to the same folder, run upload commands in
parallel for efficiency:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file1.md FOLDER_ID &
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file2.md FOLDER_ID &
wait
```

## Additional Resources

If the bundled scripts are unavailable, see
[MANUAL.md](references/MANUAL.md) for the step-by-step manual workflow.

## Troubleshooting

**Auth expired:** Run `gws auth login` to re-authenticate.
**Wrong account:** Run `gws auth status` to check which account is active.
**Upload path error:** The `gws` CLI rejects absolute paths outside cwd. Copy
the file into cwd first, or `cd` to the file's directory before uploading.
