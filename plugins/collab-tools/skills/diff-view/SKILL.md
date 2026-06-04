---
name: diff-view
description: "Generate a rich, self-contained HTML code-diff view (2-way side-by-side or 3-way) from files, pasted code, or git refs — with syntax highlighting, word-level intra-line marks, and optional full-page PNG screenshots for dropping into a PR or Slack."
when_to_use: "Use when the user wants a shareable visual diff of code — comparing two versions of a file, two similar functions, or three variants (e.g. before / after / refactored-shared). Triggers on 'diff these', 'side-by-side', 'compare these two/three', 'show the diff as HTML', 'screenshot the diff', or when a plain text/unified diff would be hard to read. Not for applying patches or routine git diffs the user just wants to read in the terminal."
allowed-tools: "Bash(node *) Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(eval *) Bash(git show *) Bash(mkdir *) Read Write Edit"
---

# diff-view

Generates a **single self-contained HTML file** that renders a rich code diff — dark GitHub-ish theme, line-numbered, syntax-highlighted, with word-level intra-line highlighting on lines that changed. No external dependencies, no network: the diff is computed by a small vanilla-JS pass embedded in the file, which runs on load. The file opens in the user's `$EDITOR`/browser and can be **screenshotted full-page** for dropping straight into a GitHub PR description or Slack.

This is a `collab-tools` skill: like its companions `temp-draft` and `promote-draft`, it routes work that doesn't belong in chat (a big visual diff) into a real artifact under `/tmp/collab-tools/`.

Two modes, auto-detected by how many sources you pass:

- **2-way** (2 sources) — side-by-side. Line-level LCS alignment; adjacent delete/insert runs pair into "changed" rows.
- **3-way** (3 sources) — three columns. A 3D LCS finds the lines common to all three (the shared "spine"); lines unique to a column stack in per-column gaps. Ideal for *before / after / extracted-shared* refactors.

## When to use this

Use it when:

- The user invokes `/collab-tools:diff-view`, or asks to "diff these", "compare side by side", "show this as an HTML diff", "screenshot the diff to share", etc.
- Comparing two versions of a file, two near-identical functions, or three variants where a unified `git diff` would be noisy or hard to read.
- The user wants something **shareable** (a screenshot for a PR/Slack), not just a terminal read.

Don't use it for:

- Applying patches, staging, or anything that mutates code.
- A quick terminal read of a small change — plain `git diff` is fine.

## How it works

A bundled Node script (`scripts/gen-diff.js`, zero dependencies — Node built-ins only, no `npm install`) templates the HTML: it injects the sources, title, column labels, and syntax keyword set, picks the 2-way vs 3-way layout, writes the `.html`, and optionally drives a headless browser to capture a PNG.

Key properties (carried over from the proven prototype, hardened for arbitrary input):

- **Whitespace-insensitive line matching** — indentation/spacing runs are collapsed for *matching*, so re-indentation never registers as a change; the original lines are still displayed verbatim.
- **Blank lines are neutral** — numbered, no highlight, never counted as a change.
- **Word-level intra-line marks** — when the present cells on a row are similar enough (Jaccard ≥ 0.34, i.e. "same line, changed"), only the tokens *not* common to the row are emphasized; genuinely different lines keep a solid tint instead of lighting up every token (avoids noise). Marks are color-coded per column.
- **Light syntax highlighting** — a single-pass tokenizer (strings / words / numbers / `$vars` / keywords / fn-calls). The keyword set is pluggable via `--lang` or `--keywords` (defaults to PHP, matching the prototype; `js`, `ts`, `python`, `go`, `ruby`, `rust`, `sql`, `generic` are built in, and the language is inferred from the file extension when `--lang` is omitted).
- **Robust embedding** — sources are embedded as ASCII-safe JS string literals (`<` → `<`, non-ASCII → `\uXXXX`). The output file is **pure ASCII** (so grep/editors don't misflag it as binary) and embedding arbitrary code — including literal `</script>`, `<`, `>`, `&`, and Unicode — round-trips losslessly. (The prototype used `<script type="text/plain">` + `textContent`, which silently breaks on any of those; this skill fixes that.)

## Procedure

### 1. Gather the sources

You need exactly **2 or 3** sources. Each can come from:

- **A file** — pass the path directly.
- **Pasted code** — write it to a temp file first (`Write` to `/tmp/collab-tools/<slug>-<role>.<ext>`), then pass that path. Keeps chat lean and gives the script a clean file.
- **A git ref** — use `--git "REF:PATH"` (e.g. `--git "HEAD~1:src/Foo.php"`), which resolves via `git show` in the current repo. Repeatable; great for "this file before vs after".

### 2. Run the generator

```bash
node "${CLAUDE_SKILL_DIR}/scripts/gen-diff.js" <sourceA> <sourceB> [sourceC] \
  --title "Short descriptive title" \
  --label "Column A label" --label "Column B label" [--label "Column C label"] \
  --lang php \
  --screenshot
```

Useful options (run with `-h` for the full list):

| Option | Purpose |
|---|---|
| `--title "..."` | Page title / H1. Defaults to a label-derived title. |
| `--subtitle "..."` | Muted one-line description under the title. |
| `--label "..."` | Column header label (repeatable, in column order). Defaults to the file basename. |
| `--sublabel "..."` | Small text under a column label (repeatable). |
| `--lang <name>` | Keyword set: `php` (default), `js`, `ts`, `python`, `go`, `ruby`, `rust`, `sql`, `generic`. Inferred from extension if omitted. |
| `--keywords "a,b,c"` | Explicit keyword list, overrides `--lang`. |
| `--note "..."` | Footer note (plain text). |
| `--git "REF:PATH"` | Add a source from a git ref (repeatable; takes precedence over positional file args). |
| `--out PATH` | Output HTML path. Defaults to `/tmp/collab-tools/<slug>-<YYYY-MM-DD>.html`. |
| `--screenshot` | Also render a full-page PNG (best-effort). |
| `--screenshot-out PATH` | PNG path. Defaults to the HTML path with `.png`. |
| `--width N` | Screenshot width in px (default 1400). |

The script prints `HTML: <path>` and (with `--screenshot`) `PNG: <path>`.

### 3. Open it for the user

Open the generated HTML the same way `temp-draft` does — non-blocking, in their editor:

```bash
eval "${EDITOR:-vi}" '/tmp/collab-tools/your-diff.html' &
disown 2>/dev/null || true
```

If the user wants to *view rendered* rather than edit source, mention they can open the `.html` in a browser (`open <path>` on macOS), or just hand them the PNG.

### 4. Report briefly

One or two lines: where the HTML landed, and the PNG path if one was produced. Don't paste the HTML or the diff body into chat — the artifact is the deliverable. If the user asked to share it, the PNG is the drag-and-drop target for a PR/Slack.

## Screenshots — what to expect

Capture is **best-effort and degrades gracefully**; the `.html` is always produced regardless.

Detection order:

1. **Playwright** (`playwright` on PATH) — preferred. Gives an **exact full-page** capture at any height, no guessing.
2. **Headless Chrome / Chromium / Edge / Brave** — fallback. Uses a fixed window whose height is estimated from the line count, so a very tall or very short page may show trailing whitespace or, rarely, clip. Still fine for most diffs.
3. **Neither found** — the script prints a clear message ("HTML written; install Playwright or Chrome to enable screenshots") and exits success. Surface that to the user; don't treat it as a failure.

If a screenshot looks clipped/padded and only Chrome was available, suggest installing Playwright (`npx playwright install chromium`) for exact full-page output, or just open the HTML in a browser.

## Examples

**Two near-identical functions (PHP), screenshot for a PR:**

```bash
node "${CLAUDE_SKILL_DIR}/scripts/gen-diff.js" /tmp/collab-tools/tag.php /tmp/collab-tools/untag.php \
  --title "TagSubscribersByFilter vs UnTagSubscribersByFilter" \
  --label "Tag (orig)" --label "UnTag (orig)" --lang php --screenshot
```

**Before / after / extracted-shared (3-way) with sublabels:**

```bash
node "${CLAUDE_SKILL_DIR}/scripts/gen-diff.js" a.php b.php shared.php \
  --title "Tag / UnTag / applyTagOperationByFilter" \
  --label "Tag()"   --sublabel "original — INSERT path" \
  --label "UnTag()" --sublabel "original — DELETE path" \
  --label "applyTagOperationByFilter()" --sublabel "new — shared" \
  --lang php --screenshot
```

**One file across two git revisions:**

```bash
node "${CLAUDE_SKILL_DIR}/scripts/gen-diff.js" \
  --git "HEAD~1:src/Subscribers.php" --git "HEAD:src/Subscribers.php" \
  --title "Subscribers.php — last commit" --label "before" --label "after" --screenshot
```

## Notes

- The diff engine is **client-side JS embedded in the output** — open the HTML anywhere (no server, no network) and it renders. The Node script only templates and (optionally) screenshots.
- Output is intentionally **pure ASCII**; non-ASCII source characters are preserved via `\uXXXX` escapes and render correctly in the browser.
- This skill never mutates the sources or the repo. It reads inputs and writes an artifact under `/tmp/collab-tools/` (or `--out`).
