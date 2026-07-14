---
name: google-doc-to-md
description: "Download a Google Doc as a local markdown file. Three source rungs: gws CLI (native text/markdown export), gcloud ADC (same clean export, different auth — for accounts gws can't reach), or the claude.ai Google Drive connector (works with zero setup, needs de-escaping). Supports native Doc tabs on the gws rung: --list-tabs and per-tab export via --tab. Triggers on \"download google doc\", \"pull from drive\", \"gdoc to markdown\", \"export google doc\", \"gws download\", or requests to pull a doc from a work/other Google account."
disable-model-invocation: true
argument-hint: '<doc-id-or-url> [output.md] [--title] [--list-tabs] [--tab <tab-title-or-id>]'
allowed-tools: 'Bash(gws *) Bash(bash *) Bash(python3 *) mcp__claude_ai_Google_Drive__download_file_content mcp__claude_ai_Google_Drive__get_file_metadata'
---

# Google Doc to Markdown

Download Google Docs as local markdown files. The Google Drive API natively
supports `text/markdown` as an export format, so no external conversion
tools are needed — the only variable is **which account can authenticate to
reach the doc**.

## Source routing

`gws` only authenticates your personal Google account. If the doc lives in
an account `gws` can't reach (e.g. a work account), route through the next
rung instead of giving up. Try rungs in order; only read/run the next rung
on fallthrough — don't front-load setup you may not need.

### Rung 1 — gws (default, unchanged)

Use the existing workflow below. This is the primary path whenever `gws`
can authenticate to the doc's account.

Fall through to rung 2 if `gws auth status` fails, or the export/metadata
call 403s/404s for the doc (wrong account, not the auth-expired case —
that's a `gws auth login` fix, not a routing fallthrough).

### Rung 2 — gcloud ADC (optional, only if configured)

Same clean native `text/markdown` export as rung 1 — same server-side
exporter — just authenticated via `gcloud` Application Default Credentials
instead of `gws`. Use this when the doc's account has ADC set up but not
`gws` (e.g. a work account you've done `gcloud auth application-default
login` for).

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/adc-check.sh   # fast preflight; exit 0 = configured
bash ${CLAUDE_SKILL_DIR}/scripts/adc-export.sh <doc-id-or-url> [output.md]
```

If `adc-check.sh` fails, it prints an actionable one-line reason. Only then
read [references/adc-setup.md](references/adc-setup.md) for the full gcloud
setup steps — don't load it up front. If ADC isn't configured and setting
it up isn't worth it right now, fall through to rung 3.

### Rung 3 — claude.ai Google Drive connector (zero setup, needs de-escaping)

Use when neither `gws` nor ADC can reach the doc's account, and the
`mcp__claude_ai_Google_Drive__*` tools are available in this session (e.g.
a work account added only via the Claude.ai connector). Verified live
(2026-07-14, see the smoke-test notes): the connector's markdown export is
**backslash-escaped** (`\#`, `\[`, `\*`, …) — there is no clean-export mode
to prefer, a de-escape pass is required.

1. Resolve the doc ID (same URL pattern as rung 1: the segment after
   `/document/d/` up to the next `/`, `?`, or `#`).
2. Call `mcp__claude_ai_Google_Drive__get_file_metadata` with `fileId` to
   confirm access and get the title.
3. Call `mcp__claude_ai_Google_Drive__download_file_content` with
   `fileId` and `exportMimeType: "text/markdown"`. Base64-decode the
   returned `content` (e.g.
   `python3 -c "import sys,base64; sys.stdout.write(base64.b64decode(sys.argv[1]).decode('utf-8'))" "$B64"`
   or write to a temp file and `base64 -d`).
4. De-escape it:
   ```bash
   python3 ${CLAUDE_SKILL_DIR}/scripts/deescape.py TEMP_INPUT.md CLEANED.md
   ```
5. Write `CLEANED.md`'s content to the output file (same filename-derivation
   rules as rung 1).

**Known limitation:** a literal backslash in the source prose immediately
followed by punctuation (e.g. `C:\*.txt`) is indistinguishable from a
connector-introduced escape and will also get unescaped. Low risk for prose
docs; call it out if the source doc is code-heavy or path-heavy.

If none of the three rungs can reach the doc, fail with a clear message
naming which rungs were tried and why each failed — don't silently give up
after rung 1.

## Prerequisites (rung 1)

```!
gws auth status 2>&1 || echo "NOT AUTHENTICATED — run: gws auth login"
```

## Task (rung 1)

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

## Working with Native Doc Tabs

List a doc's tabs (id, index, title — indented by nesting):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID --list-tabs
```

Export a single tab as markdown (basic fidelity: headings, bold/italic,
links, lists, tables):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID out.md --tab "Tab Title"
```

Note: the default (no `--tab`) Drive export flattens ALL tabs into one
markdown file with each tab's title as a heading — fine for single-tab docs,
confusing for multi-tab ones. Use `--list-tabs` first when unsure.

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
**Account mismatch:** If the doc belongs to a different Google account,
the script will tell you which account you're authenticated as and suggest
sharing or switching accounts. Run `gws auth status` to check.
**Empty output:** The doc may be empty or the export may have failed — check
stderr for error messages.
