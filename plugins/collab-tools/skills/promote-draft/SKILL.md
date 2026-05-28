---
name: promote-draft
description: "Move a draft out of /tmp/collab-tools/ (or an explicit source path) into its real home, optionally renaming off the -draft / -YYYY-MM-DD suffix."
when_to_use: "Use when the user invokes /promote-draft, or when they say the temp-draft is ready, ask to 'move the draft to <path>', 'promote this draft', 'land the draft', or otherwise indicate that a draft should now live somewhere permanent. Do NOT use for arbitrary file moves — this is specifically the companion to the temp-draft skill. The default source location is /tmp/collab-tools/, but the user may name any source path explicitly."
---

# promote-draft

Companion to `temp-draft` skill. Once a draft in `/tmp/collab-tools/` is ready to live somewhere permanent — a blog post directory, a project doc, an email file, a code snippet in a repo — this skill moves it out of the staging dir, optionally renames off the "drafty" filename, and surfaces the right next step (typically `git add`).

The default source location is `/tmp/collab-tools/` (where `temp-draft` writes). The user can also pass an explicit source path from anywhere in the filesystem — useful for drafts that started somewhere else or were created in a prior session.

The same content-stays-in-the-file philosophy applies: the file is the deliverable, chat stays lean. Do not paste the draft contents during this skill.

## When to use this

Use this skill when:

- The user invokes `/promote-draft` directly.
- The user explicitly says "move the draft to X", "promote that draft", "land the draft", "the draft is done — put it in <path>", or any equivalent.
- The user finished iterating on a temp-draft in editor and now references where it should live.

Don't use this skill for:

- General file moves unrelated to a temp-draft.
- Copying drafts — this skill moves, it does not duplicate.
- Renaming a file in place. If they just want a rename, use `Bash` with `mv`.

## Procedure

### 1. Identify the source file

Decide in this order:

1. **Argument is an explicit path** — use it. The source can be anywhere in the filesystem when the user names it directly. Don't restrict to `/tmp/collab-tools/` in this case.
2. **The current conversation created a temp-draft** — use that path. Look back through this session's tool calls for a `Write` to a `/tmp/collab-tools/*` path or an `eval "${EDITOR:-vi}" '/tmp/collab-tools/...'` invocation; that's almost certainly the file.
3. **Otherwise, list candidates** from the temp-draft staging directory and ask the user which to promote:

   ```bash
   ls -lt /tmp/collab-tools/ 2>/dev/null | head -10
   ```

   Show the candidates and ask. Don't guess if more than one is plausible. If the directory is empty or doesn't exist, tell the user there's nothing to promote and stop — don't go fishing through other `/tmp` paths uninvited.

Verify the source exists before doing anything else: `test -f "<source>" || ...` and stop with a clear error if it doesn't.

### 2. Determine the destination path

Parse `$ARGUMENTS` for a destination. Common shapes:

- `/temp-draft promote ~/blog/posts/` — destination is a directory; keep the filename (after rename, see step 3).
- `/temp-draft promote ~/blog/posts/my-new-post.md` — destination is a full path; use as-is.
- No path given — ask the user where it should go.

If the destination directory doesn't exist, ask before creating it (`mkdir -p`). Don't silently materialize new directory trees.

### 3. Offer a rename

Temp-draft filenames follow `<slug>-YYYY-MM-DD.<ext>`. That `-YYYY-MM-DD` suffix is useful for triage in `/tmp` but usually doesn't belong in the permanent name.

If the basename contains any of these patterns, propose a cleaner name:

- `-draft` anywhere in the slug → remove.
- `-YYYY-MM-DD` at the end of the stem → remove (the file's mtime / git history will preserve the date).
- Generic words like `temp`, `wip`, `scratch` in the slug → ask whether to drop.

Show the user the proposed before / after and confirm. Example:

> Rename `cold-email-to-acme-draft-2026-05-28.md` → `cold-email-to-acme.md`? (Y/n)

If the user is silent on this and the destination already specifies a full filename, use the user's chosen filename — don't override.

### 4. Move the file

```bash
mv "<source>" "<final-destination>"
```

If the destination resolves to the same path as the source for whatever reason, stop — there's nothing to do.

### 5. Surface the right next step

After the move:

- Run `git -C "<dest-dir>" rev-parse --show-toplevel 2>/dev/null` to detect whether the destination is inside a git repo.
- If yes: tell the user the file is at the new path and suggest `git add "<final-destination>"` as the next step. Do **not** stage or commit automatically — committing is the user's decision.
- If no: just confirm the new path.

One short sentence either way. Don't paste the draft's contents.

## What this looks like

Good:

> Moved `/tmp/collab-tools/cold-email-to-acme-2026-05-28.md` → `~/work/emails/cold-email-to-acme.md`. It's in a git repo — `git add ~/work/emails/cold-email-to-acme.md` when you're ready.

Bad:

> Here's the final draft now living at ~/work/emails/cold-email-to-acme.md:
>
> Subject: ...
> ... 200 lines pasted into chat ...

## Edge cases

- **Destination already exists.** Stop and ask. Don't clobber. Offer to (a) pick a new name, (b) overwrite, or (c) cancel.
- **Source has no obvious temp-draft markers.** Promote it anyway if the user is explicit — this skill isn't gatekeeping which files in `/tmp` count as drafts.
- **User wants to promote multiple files at once.** Loop the procedure per file. Confirm renames individually.
- **Cross-device move (e.g., source on a different volume).** `mv` handles it. If it fails, fall back to `cp && rm` and report what happened.
