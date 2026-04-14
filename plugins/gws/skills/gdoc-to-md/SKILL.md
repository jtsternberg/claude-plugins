---
name: gdoc-to-md
description: Download a Google Doc as a local markdown file via gws CLI. Uses native text/markdown export from the Drive API. Triggers on "download google doc", "pull from drive", "gdoc to markdown", "export google doc", "gws download".
argument-hint: <doc-id-or-url> [output.md] [--title]
allowed-tools: Bash(gws *) Bash(bash *) Bash(python3 *)
---

# Google Doc to Markdown

Download Google Docs as local markdown files using the `gws` CLI.
The Google Drive API natively supports `text/markdown` as an export format,
so no external conversion tools are needed.

## Prerequisites

```!
gws auth status 2>&1 || echo "NOT AUTHENTICATED — run: gws auth login"
```

## Task

Run the entrypoint script, passing all arguments through:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh $ARGUMENTS
```

If no arguments were provided, ask the user for the Google Doc URL or ID
and optionally the output file path.

## Script Details

### Downloading a Google Doc

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID_OR_URL
```

With a custom output path:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID_OR_URL ./output.md
```

With `--title` flag to use the doc's title as the filename:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID_OR_URL --title
```

### How It Works

1. Extracts the doc ID from a URL if a full URL is provided
2. Fetches the document title from Google Drive metadata
3. Exports the doc as markdown via `gws drive files export` with
   `mimeType: text/markdown` (native Drive API support)
4. Writes the result to the output file

### Extracting a Doc ID

The doc ID is the long string in a Google Docs URL:
`https://docs.google.com/document/d/DOC_ID_HERE/edit`

### Output Filename

When no output path is given:
1. If `--title` is set, derives the filename from the Google Doc title
   (lowercased, spaces to hyphens, `.md` extension)
2. Otherwise defaults to `<doc-id>.md` in the current directory

### Export Size Limit

Google limits exported content from `files.export` to **10 MB**.

## Batch Downloads

When downloading multiple docs, run in parallel:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_URL_1 ./doc1.md &
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_URL_2 ./doc2.md &
wait
```

## Additional Resources

If the bundled scripts are unavailable, see
[MANUAL.md](references/MANUAL.md) for the step-by-step manual workflow.

## Troubleshooting

**Auth expired:** Run `gws auth login` to re-authenticate.
**Wrong account:** Run `gws auth status` to check which account is active.
**Empty output:** The doc may be empty or the export may have failed — check
stderr for error messages.
