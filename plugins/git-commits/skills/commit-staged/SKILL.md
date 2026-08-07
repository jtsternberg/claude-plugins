---
name: commit-staged
description: Create a commit from already staged changes, using a supplied message or a concise conventional commit message inferred from the diff.
argument-hint: "Optional commit message (will be generated if not provided)"
disable-model-invocation: true
allowed-tools: [Bash]
---

# Commit Staged Changes

Use this skill only when the user explicitly asks to commit their staged changes.

**Arguments provided:** $ARGUMENTS

Codex: if the invocation text above is not populated, use a commit message supplied after the skill name or in the current request. If none is available, infer the message from the diff.

## Workflow

1. Inspect the repository state with `git status`, `git diff`, and `git diff --cached`.
2. Stop if there are no staged changes. Do not create an empty commit.
3. Respect a commit message supplied by the user. Otherwise, derive a concise conventional commit message from the staged diff and the repository's recent commit style (`git log`).
4. Check that the staged files do not include secrets or private configuration (for example `.env`, credential files, tokens, or private keys). Stop and tell the user if they do.
5. Create the commit from the staged files. Do not amend, use `--no-verify`, or push unless the user explicitly asks.
6. Report the commit hash and the remaining `git status` state.

If the staged diff contains unrelated changes, stop before committing and ask the user to split or clarify the intended scope.
