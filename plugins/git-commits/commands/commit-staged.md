---
description: Create a commit from currently staged files
argument-hint: Optional commit message (will be generated if not provided)
allowed-tools: [Bash]
---

# Commit Staged Files

I'll create a commit from the currently staged files.

**Arguments provided:** $ARGUMENTS

## Process:

1. **Check staged files** - Review what changes are staged for commit
2. **Generate commit message** - Create an appropriate commit message (if not clearly provided in arguments)
3. **Create commit** - Execute the git commit with proper formatting

If you provided a commit message in the arguments, I'll use that. Otherwise, I'll analyze the staged changes and generate an appropriate commit message.

Let me start by checking the current git status and staged changes.