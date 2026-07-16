---
name: md-to-google-doc
description: "Upload markdown to Google Drive as a Google Doc. Three source rungs: gws CLI (full create/update/tab support), gcloud ADC (create + update-in-place via a state file, for accounts gws can't reach), or the claude.ai Google Drive connector (zero setup, create-only, no update/no pageless/no table-cell emphasis). Strips frontmatter and Obsidian callouts. Triggers on \"upload to google docs\", \"push to drive\", \"sync to gdoc\", \"create a google doc\", \"gws upload\", or requests to push markdown to a work/other Google account."
disable-model-invocation: true
argument-hint: '[file.md] [folder-id-or-url | --folder <id-or-url> | doc-id-or-url] [--title "Title"]'
allowed-tools: 'Bash(gws *) Bash(bash *) Bash(python3 *) mcp__claude_ai_Google_Drive__create_file'
---

# Markdown to Google Doc

Upload local markdown files to Google Drive as formatted Google Docs. The
best available path depends on **which account can authenticate** and how
much fidelity the target doc needs.

## Source routing

`gws` only authenticates your personal Google account. If the target doc's
account isn't reachable by `gws`, route through the next rung — try in
order, and only read/run the next rung's setup on fallthrough.

### Rung 1 — gws (default, unchanged)

Use the existing workflow below: full create, update-in-place, tab
management, section linking. This is the primary path whenever `gws` can
authenticate to the target account.

Fall through to rung 2 if `gws auth status` fails or the target account
can't reach the destination folder/doc (403/404 for that account, not an
expired-token case).

### Rung 2 — gcloud ADC (create + update-in-place, for accounts gws can't reach)

Direct Drive/Docs API access via ADC. Supports create (`files.create` with
a markdown upload — same server-side importer `gws` uses) and
**update-in-place**: a state file
(`~/.config/gws-md-to-gdoc/rendered.json`) remembers which source file
produced which doc ID, so reruns update instead of duplicating. Sets
PAGELESS via a `batchUpdate` after create, same as `gws`.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/adc-check.sh   # fast preflight; exit 0 = configured
bash ${CLAUDE_SKILL_DIR}/scripts/adc-create.sh <file.md> [folder-id-or-url] [--title "Title"] [--new]
```

`--new` forces a fresh doc even if the state file has a prior entry for this
source file. If `adc-check.sh` fails, it prints an actionable one-line
reason — only then read
[references/adc-setup.md](references/adc-setup.md) for the full gcloud
setup steps. If ADC isn't configured and setting it up isn't worth it right
now, fall through to rung 3.

Not supported on this rung yet: tab-scoped publishing, section linking (both
gws-only for now).

### Rung 3 — claude.ai Google Drive connector (zero setup, create-only)

Use when neither `gws` nor ADC can reach the target account, and the
`mcp__claude_ai_Google_Drive__*` tools are available in this session.
Verified live (2026-07-14): `create_file` with `contentMimeType:
"text/markdown"` produces a real formatted Google Doc (headings, bold,
links, lists, tables) — no de-escaping needed on this direction, this is
the connector's write path, not its read path.

1. Clean the markdown (same as rung 1/2):
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/clean.sh <file.md> /tmp/cleaned-$$.md
   ```
2. Derive the title if `--title` wasn't given (H1 heading, else filename).
3. Call `mcp__claude_ai_Google_Drive__create_file`:
   - `title`: derived/given title
   - `textContent`: the cleaned markdown content
   - `contentMimeType`: `"text/markdown"`
   - `parentId`: target folder ID if `--folder` was given (strip a full
     `.../folders/FOLDER_ID` URL the same way as folder-ID extraction
     elsewhere in this skill)
   - leave `disableConversionToGoogleType` unset — default conversion is
     what formats the Doc.
4. Report the URL: `https://docs.google.com/document/d/<id>/edit` (the `id`
   field `create_file` returns).
5. Clean up the temp file.

**Refuse update requests on this rung.** The connector's `update_file` tool
only renames/moves — it cannot replace content, and `trash_file` fails with
a permission error (confirmed live — no delete means no throwaway-temp-doc
tricks either). If asked to update an existing doc and only this rung is
available, say so and point at rung 2 (ADC update-in-place) instead of
silently creating a duplicate doc.

**Known limits** (confirmed live): no bold/italic/inline emphasis inside
table cells (stays literal `**text**`); no way to set PAGELESS mode (new
docs land in Drive's default paged mode); same unsupported set as gws
(images, footnotes, smart chips) presumed but not individually verified on
this rung.

If none of the three rungs can reach the destination, fail with a clear
message naming which rungs were tried and why each failed.

## Prerequisites (rung 1)

```!
gws auth status 2>&1 || echo "NOT AUTHENTICATED — run: gws auth login"
```

## Task (rung 1)

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

The folder may be a bare ID or a full Drive folder URL, and may be passed
positionally or via `--folder`. All of these are equivalent:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file.md FOLDER_ID
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file.md "https://drive.google.com/drive/u/0/folders/FOLDER_ID"
bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh ./file.md --folder "https://drive.google.com/drive/u/0/folders/FOLDER_ID"
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

### Updating a Single Tab (multi-tab docs)

Google Docs supports native tabs (left-sidebar). `update.sh` replaces the
ENTIRE document and **deletes every tab except the first** — it refuses to
run against a multi-tab doc unless you pass `--force`.

To publish markdown into one tab while preserving the others:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/tab-update.sh ./file.md DOC_ID --tab "Tab Title"
bash ${CLAUDE_SKILL_DIR}/scripts/tab-update.sh ./file.md DOC_ID --tab t.abc123
```

How it works: the markdown is converted server-side via a throwaway temp doc
(auto-trashed), whose structure is replayed into the target tab with
tab-scoped `batchUpdate` requests. Supported: headings, bold/italic/links,
nested bullet & numbered lists, tables, and horizontal rules (`---`, rendered
as a paragraph bottom border). Not supported (skipped with a warning): images,
footnotes, smart chips.

### Linking Section References Across Tabs

After publishing, turn `§N` / `§NB` references into clickable links to the
matching section heading in another tab (e.g. a "Next Steps" tab linking into
the main findings tab):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/link-sections.sh DOC_ID
bash ${CLAUDE_SKILL_DIR}/scripts/link-sections.sh DOC_ID --target-tab "Findings" --from-tab "Next Steps"
```

By default the target is the tab with the most numbered-section headings and
all other tabs are scanned. Idempotent — safe to re-run after edits. Run it
*after* the tabs are published so the target headings exist.

### Managing Tabs

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh list DOC_ID
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh add DOC_ID "Next Steps" --emoji "⭐" --index 1
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh rename DOC_ID "Next Steps" "Action Items"
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh delete DOC_ID t.abc123 --yes
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
**Account mismatch:** If the doc/folder belongs to a different Google account,
the script will tell you which account you're authenticated as and suggest
sharing or switching accounts. Run `gws auth status` to check.
**Upload path error:** The `gws` CLI rejects absolute paths outside cwd. Copy
the file into cwd first, or `cd` to the file's directory before uploading.
**"This doc has N native tabs" error:** the doc uses native tabs; use
`tab-update.sh` (see "Updating a Single Tab") or pass `--force` to
intentionally flatten the doc to one tab.
