---
description: Stage all unstaged files and create a commit
argument-hint: Optional commit message (will be generated if not provided)
allowed-tools: [Bash]
---

# Commit Unstaged Files

I'll stage all currently unstaged files and create a commit.

**Arguments provided:** $ARGUMENTS

## Process:

1. **Check unstaged files** - Review what changes are currently unstaged
2. **Stage all files** - Add all unstaged changes to the staging area _individually_. This allows an easy review of what files would be included to prevent accidental inclusion of files that should not be committed.
3. **Generate commit message** - Create an appropriate commit message (if not clearly provided in arguments)
4. **Create commit** - Execute the git commit with proper formatting

If you provided a commit message in the arguments, I'll use that. Otherwise, I'll analyze the changes and generate an appropriate commit message following the established format with the Claude Code signature.

Let me start by checking the current git status and unstaged changes.