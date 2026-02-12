---
description: Hand off to the next agent with fresh context
allowed-tools: Bash, Read, Write
---

Write or update a handoff document so the next agent with fresh context can continue this work.

Steps:
1. Get the current git branch name via `git branch --show-current` to use as the filename suffix (e.g., branch `fix-auth` → `HANDOFF-fix-auth.md`). If not in a git repo or on a detached HEAD, omit the suffix and use `HANDOFF.md`.
2. Check if the handoff file already exists in the current working directory
3. If it exists, read it first to understand prior context before updating
4. Create or update the document with:
   - **Goal**: What we're trying to accomplish. If the goal evolved from the original ask, note how and why.
   - **Current Progress**: What's been done so far
   - **Files Changed**: List of files modified, created, or deleted this session
   - **What Worked**: Approaches that succeeded
   - **What Didn't Work**: Approaches that failed (so they're not repeated)
   - **Next Steps**: Clear action items for continuing

Save the file in the current working directory, then output:

```
Handoff saved to [absolute path to file]

To resume, start a new conversation and paste:
Read [absolute path to file] and continue where we left off
```