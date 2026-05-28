---
name: temp-draft
description: "Route a draft to a file in /tmp opened in the user's $EDITOR instead of pasting it into chat."
when_to_use: "Use when the user invokes /temp-draft, or when they explicitly ask to draft in their editor / in a temp file / collaboratively in editor. Do NOT use for routine writing, short replies, or edits to existing project files — most content belongs in chat or in its real home."
allowed-tools: Write Edit Bash
---

# temp-draft

The user prefers to collaborate on long-form drafts in their own text editor rather than read them inline in chat. This skill exists to break the default habit of pasting drafted content directly into responses — which is hard to edit, hard to save, eats context, and loses formatting / syntax highlighting.

## When to use this

Use this skill when:

- The user invoked `/temp-draft` directly.
- The user explicitly said something like "draft this in editor", "open it in a temp file", "let's draft collaboratively", "put the draft in /tmp", or any equivalent phrasing.

Don't use this skill for:

- Quick one-line answers or short replies that belong inline.
- Edits to existing files in the project — use `Edit` / `Write` against the real file.
- Brainstorming or back-and-forth conversation where the user is reading along.
- Code or docs that have an obvious real destination (e.g., a function in `src/`, a section in `README.md`). The temp file is for drafts without a permanent home yet.

When in doubt, ask the user once whether they want the draft in chat or in `/tmp`. Guessing wrong wastes a turn either way.

## Procedure

1. **Pick a descriptive filename.** Format: `/tmp/collab-tools/<short-slug>-<YYYY-MM-DD>.<ext>`.
   - All drafts live under `/tmp/collab-tools/` so the companion `promote-draft` skill can find them. Create the directory if it doesn't exist: `mkdir -p /tmp/collab-tools`.
   - `<short-slug>` is 3-5 kebab-case words describing the draft. Match the content, not generic ("blog-post-fence-fences", not "draft").
   - `<ext>` matches the content type: `.md` for prose, plans, notes, structured docs; `.txt` for plain unformatted text; `.html`, `.py`, `.ts`, etc. for code.
   - Examples:
     - `/tmp/collab-tools/cold-email-to-acme-2026-05-28.md`
     - `/tmp/collab-tools/refactor-plan-auth-module-2026-05-28.md`
     - `/tmp/collab-tools/talk-outline-react-conf-2026-05-28.md`

2. **Write the draft to that file** using the `Write` tool. The file is the deliverable.

3. **Open it in the user's editor** with this exact form:

   ```bash
   eval "${EDITOR:-vi}" '/tmp/collab-tools/your-file.md'
   ```

   The `eval` form is what makes multi-word editor settings work — values like `code --wait`, `cursor --wait`, or `subl -n -w` need shell-level word splitting. Single-quote the path so spaces and special characters are safe.

4. **Briefly tell the user where it landed.** One short sentence with the path. Do NOT paste the draft content into the chat — the entire point is that the chat stays clean and the work lives in the editor.

## What this looks like

Good:

> Drafted to `/tmp/collab-tools/blog-post-fence-fences-2026-05-28.md` and opened in your editor.

Bad:

> Here's the draft:
>
> # Don't Tear Down the Fence
>
> ... 600 lines of pasted markdown ...

## Why "draft in chat" is the wrong default for this user

Pasting long drafts into the chat:

- Burns context the user will need for follow-up turns.
- Forces the user to copy-paste back into an editor to actually work with the text.
- Loses syntax highlighting, spellcheck, find/replace, and every other editor affordance.
- Makes iterative edits painful — every change re-renders the whole block.

A file in `/tmp/collab-tools/` opened in `$EDITOR` keeps chat lean, gives the user real editing power, and lets both sides refer back to "the draft" by path across many turns. The shared directory also gives the companion `promote-draft` skill a known place to look when moving a finished draft to its permanent home.

## Notes for follow-up turns

After the draft is in `/tmp`, the user may iterate on it — asking for changes, additions, sections to rewrite. Edit the file with the `Edit` tool and tell the user briefly what changed. Still don't paste the contents.

If the draft is ready to live somewhere permanent (a blog post directory, a project doc, an email client), that's a separate operation — surface the file path and let the user decide where it goes, or ask if they want it moved.
