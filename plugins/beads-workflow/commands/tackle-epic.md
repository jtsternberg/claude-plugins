---
description: Work on an epic from beads until completion, then create a PR
argument-hint: <epic-id-or-name>
---

# Tackle Epic

You are given an epic identifier: `$ARGUMENTS`

## Step 1: Find the Epic

First, locate the epic in beads:

1. If the argument looks like an ID (e.g., `buddy-cli-98w`), run: `bd show $ARGUMENTS`
2. If it's a name/search term, run: `bd list --type=epic --title="$ARGUMENTS"` to find matching epics

If no epic is found, report the error and stop.

## Step 2: Understand the Epic

Once you have the epic:

1. Run `bd show <epic-id>` to get full details
2. Run `bd show <epic-id> --children` to see all child tasks
3. Understand the scope and requirements from the epic description

## Step 3: Create a Worktree

Create a worktree for this epic (not just a branch):

1. Generate a branch name from the epic title/context (lowercase, hyphenated, max 50 chars)
   - Format: `feature/<epic-id>-<short-description>`
   - Example: `feature/buddy-cli-98w-webhook-management`
2. Create the worktree: `git worktree add ../<repo-name>-<short-description> -b <branch-name>`
3. Change into the worktree directory and continue all work there

## Step 4: Work on Tasks

For each child task of the epic (in priority order):

1. Run `bd ready --parent=<epic-id>` to find tasks ready to work on
2. **Parallelization**: When multiple ready tasks are independent (different files, no shared state), delegate them to sub-agents using the Task tool to work in parallel. Only parallelize tasks unlikely to conflict.
3. For each ready task:
   - Run `bd update <task-id> --status=in_progress`
   - Complete the work required
   - **Commit immediately**: Stage specific files and create a granular commit for this task
   - Run `bd close <task-id>`
3. Continue until all children are complete

Create granular commits throughout the process - one commit per logical unit of work (typically per task). Never batch all changes into a single commit at the end.

If there are no child tasks, work directly on the epic's requirements, still committing granularly as you complete logical units.

## Step 5: Check README

After completing the work:

1. Review the changes made: `git diff --name-only`
2. Assess if README.md needs updates based on:
   - New features added
   - Changed CLI commands or options
   - New configuration options
   - Breaking changes
3. If updates are needed, edit README.md to document the changes

## Step 6: Final Commit and Push

1. If README was updated, commit it separately
2. Verify all changes are committed: `git status`
3. Push the branch: `git push -u origin <branch-name>`

Note: Most commits should already exist from Step 4. This step handles any final changes and the push.

## Step 7: Create Pull Request

Create a PR using gh CLI:

```bash
gh pr create --title "<Epic title>" --body "$(cat <<'EOF'
## Summary
<Brief description of what this epic accomplishes>

## Changes
<List of key changes made>

## Related
- Epic: <epic-id>
- Child tasks: <list of closed task IDs>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Step 8: Close the Epic

After the PR is created:

1. Run `bd close <epic-id>` to mark the epic complete

Report the PR URL when finished.
