---
description: Fix a list of issues one-by-one, each with its own beads task, commit, and push
argument-hint: "--push"
---

Fix the issues/findings from this conversation, each tracked with a beads task and committed individually.

✅ DO ONE COMMIT PER FIX.
❌ DO NOT CREATE ONE BIG COMMIT.

$ARGUMENTS

## Workflow

1. **Identify findings** from the conversation. If ambiguous, confirm with user first.

2. **Create one beads task per finding** (`bd create`), ordered by severity.

3. **Fix each finding individually** — never batch:
   - `bd update [id] --status=in_progress`
   - Re-read files fresh (prior fixes may have changed them)
   - Apply focused fix
   - Lint changed files per project CLAUDE.md
   - Commit only files for THIS fix (no `git add .`)
   - `bd close [id]`
   - push to remote if specified with --push
   - Move to next

4. **Show summary** when done:
   | # | Finding | Commit | Beads Task |
   |---|---------|--------|------------|

## Rules

- **One commit per fix.** Never combine findings.
- **If specified, push to remote after each commit.** Never accumulate.
- **Always re-read files before editing.** Prior fixes may have changed them.
- **If unclear, ask.** Don't guess.
