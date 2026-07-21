---
description: Hand off to the next agent with fresh context
allowed-tools: Bash, Read, Write
---

Write or update a handoff document so the next agent with fresh context can continue this work.

Steps:
1. Choose a filename suffix that describes the **work**, not just the branch:
   - Default to the current git branch name via `git branch --show-current` (e.g., branch `fix-auth` → `HANDOFF-fix-auth.md`).
   - **But** when the branch name doesn't describe the work — a generic default branch (`main`, `master`, `develop`, `trunk`), a bare ticket ID, or a branch carrying several unrelated tasks — pick a short kebab-case suffix from what this session is actually about (e.g. `HANDOFF-grafana-skill.md`). Prefer a descriptive suffix over an uninformative `HANDOFF-master.md`.
   - If not in a git repo or on a detached HEAD, and the work has no obvious short name, omit the suffix and use `HANDOFF.md`.
   - If a handoff file for this work already exists (see step 2), reuse its name rather than creating a second one.
2. Check if the handoff file already exists in the current working directory
3. If it exists, read it first to understand prior context before updating
4. Create or update the document. Start it with a pickup banner at the very top (before the Goal), so the next agent knows how to resume:

   ```
   > **Resuming this work?** Run `/pickup-handoff` (or paste: `Read <absolute path to this file> and continue where we left off`).
   ```

   Then include:
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