---
name: fix-findings-beads-tasks
description: Fix a list of issues one-by-one, each with its own beads task, commit, and push
argument-hint: "--push"
disable-model-invocation: true
---

Fix the issues/findings from this conversation, each tracked with a beads task and committed individually.

✅ DO ONE COMMIT PER FIX.
❌ DO NOT CREATE ONE BIG COMMIT.

$ARGUMENTS

Codex: if the invocation text above is not populated, use the text after the skill name. If none is available, infer the findings and optional `--push` flag from the current request.

## Workflow

0. **Load project conventions (if available):**
   If the `CODE_CONVENTIONS` environment variable is set and points to a readable file, read it before starting fixes. Each fix should respect these conventions to avoid introducing new violations while resolving existing ones. If unset, skip this step.

1. **Identify findings** from the conversation. If ambiguous, confirm with user first.

2. **Create one beads task per finding** (`bd create`), ordered by severity.

3. **Fix each finding individually** — never batch:
   - `bd update [id] --status=in_progress`
   - Re-read files fresh (prior fixes may have changed them)
   - Apply focused fix
   - Lint changed files per applicable `AGENTS.md`, `CLAUDE.md`, and other repository instructions
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
