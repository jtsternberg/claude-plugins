# Collab Tools Plugin

Skills that help Claude collaborate more naturally — routing work out of chat and into appropriate channels (files, editors, the filesystem) when chat isn't the right surface.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install collab-tools@jtsternberg
```

## Description

The default behavior for an LLM is to dump everything into the chat. That works for short answers and inline conversation, but it gets in the way for long-form drafting work — blog posts, emails, refactor plans, talk outlines — where the user wants real editor tools and a persistent file they can iterate on across many turns.

The skills in this plugin shift that default for the cases where it matters. They keep chat lean and give the user a real file to work with.

## Skills

### `/collab-tools:temp-draft`

Routes a long-form draft to `/tmp/collab-tools/<slug>-<YYYY-MM-DD>.<ext>` opened in your editor — instead of having Claude paste the full draft into chat. Keeps context lean, gives you real editor affordances (syntax highlighting, find/replace, spellcheck), and makes iterative edits painless.

When the draft is a Slack message, the skill writes Slack-flavored markup instead of standard markdown — no headings (bold section labels instead), `*single-asterisk*` bold, `_underscore_` italic, code fences without language tags, and bare URLs instead of `[text](url)` — so pasting into Slack (with `cmd+shift+f` formatting conversion) leaves no artifacts. Slack drafts are saved as `.txt` (a `.md` file makes editors copy rich text, which corrupts the paste).

The editor command is `OPEN_IN_EDITOR_COMMAND`, falling back to `$EDITOR`, then `vi`. Set `OPEN_IN_EDITOR_COMMAND` when your `$EDITOR` is a blocking/`--wait` command (e.g. `code --wait`): a backgrounded `--wait` editor leaves a live process waiting for the file to close, which shows as a duplicate "ghost" app instance in the macOS app switcher. `export OPEN_IN_EDITOR_COMMAND=code` (no `--wait`) opens the file in your existing window and returns immediately.

```
/collab-tools:temp-draft Draft a cold email to the Acme team introducing our Q3 partnership.
```

Or just describe a long-form thing you'd rather edit in your editor than read in chat — Claude reaches for the skill when the context matches.

### `/collab-tools:promote-draft`

Companion to `temp-draft`. Moves a finished draft out of `/tmp/collab-tools/` (or any explicit source path) to its real home, optionally strips the `-draft` / `-YYYY-MM-DD` suffix from the filename, and suggests `git add` if the destination is inside a repo. Never auto-commits — staging is your call.

```
/collab-tools:promote-draft ~/blog/posts/
/collab-tools:promote-draft ~/work/emails/cold-email-acme.md
```

If no destination is given, the skill asks. If no source is given, it pulls candidates from `/tmp/collab-tools/`. Explicit source paths can come from anywhere in the filesystem.

### `/collab-tools:diff-view`

Generates a rich, **self-contained HTML code-diff view** — 2-way side-by-side or 3-way — from files, pasted code, or git refs, and can screenshot it full-page for dropping straight into a GitHub PR or Slack. Dark GitHub-ish theme, line numbers, syntax highlighting, and word-level intra-line marks on lines that changed. The diff is computed by a small vanilla-JS pass embedded in the file (no dependencies, no network); the output lands under `/tmp/collab-tools/` and opens in `$EDITOR`/browser.

```
/collab-tools:diff-view Compare the old and new versions of this function side by side and screenshot it.
```

- **2-way** (2 sources): line-level LCS alignment, adjacent del/insert runs paired into "changed" rows.
- **3-way** (3 sources): a 3D LCS finds the lines shared by all three (the spine); column-unique lines stack in per-column gaps — ideal for *before / after / extracted-shared* refactors.

Whitespace-insensitive matching (re-indentation isn't a change), blank lines neutral, pluggable syntax keyword set (`--lang php|js|ts|python|go|ruby|rust|sql|generic`, inferred from extension by default). Screenshots are best-effort: Playwright (exact full-page) → headless Chrome (fallback) → graceful HTML-only message if no browser is found.

## Philosophy

Both skills follow the same rule: **the file is the deliverable, chat stays lean.** Neither skill pastes the draft body into chat — they confirm the path and let the user work in their editor. This keeps token context budget available for follow-up turns and gives the user real editing power instead of a Markdown blob in a scrollback buffer.
