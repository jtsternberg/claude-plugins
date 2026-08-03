---
name: commit-unstaged
description: Review unstaged changes, stage the intended files explicitly, and create a commit with a supplied or concise conventional message.
disable-model-invocation: true
allowed-tools: [Bash]
---

# Commit Unstaged Changes

Use this skill only when the user explicitly asks to stage and commit their current changes.

## Workflow

1. Inspect the repository state with `git status`, `git diff`, and `git diff --cached`.
2. Identify the files that belong in this commit. Do not use `git add -A` or `git add .`; stage each intended file by explicit path.
3. Stop if the intended files include secrets or private configuration (for example `.env`, credential files, tokens, or private keys). Do not stage them.
4. Review the staged diff. If it contains unrelated changes, unstage the unrelated paths or ask the user to split the work before committing.
5. Respect a commit message supplied by the user. Otherwise, derive a concise conventional commit message from the staged diff and the repository's recent commit style (`git log`).
6. Create the commit. Do not amend, use `--no-verify`, or push unless the user explicitly asks.
7. Report the commit hash and the remaining `git status` state.

If there are no unstaged changes, say so and do not create an empty commit.
