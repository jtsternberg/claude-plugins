---
name: git-tree
description: Create git worktrees with symlinked dependencies. Use when user says "git worktree", "work on two branches", "parallel branch work", "review PR without switching", "keep my changes while checking out another branch", or wants isolated branch directories sharing vendor/node_modules.
---

# Git Tree

Create git worktrees in parallel directories with automatic symlinks to vendor, node_modules, and .env.

## Quick Reference

```bash
# From skill directory
SKILL_DIR="$HOME/.claude/skills/git-tree"
$SKILL_DIR/scripts/git-tree.sh <branch-name> [--repo <path>] [--create]
```

## Workflow

Run the script with the branch name. If no branch provided, ask the user.

```bash
SKILL_DIR="$HOME/.claude/skills/git-tree"
$SKILL_DIR/scripts/git-tree.sh <branch-name> [--repo <path>] [--create]
```

**Flags:**
- `--repo <path>`: Target repository (defaults to cwd)
- `--create`: Create branch if it doesn't exist

**Success output:**
```
Worktree created successfully
Created N symlink(s)
Worktree location: /path/to/gittree-branch
```

**Failure:** Script exits non-zero with error message. Common errors:
- "Branch does not exist" → add `--create` flag or create branch first
- "Worktree directory already exists" → remove existing worktree
- "Branch is already checked out" → use different branch or remove other worktree

## What Gets Created

```
parent/
├── repo/                # Original (real deps)
└── gittree-branch/      # Worktree (symlinked deps)
```

## Managing Worktrees

```bash
# List all worktrees
git worktree list

# Remove a worktree
git worktree remove gittree-branch-name
```

## When NOT to Use

- **Different dependency versions needed** → Remove symlinks and install: `rm vendor && composer install`
- **Temporary one-file changes** → Use `git stash`
- **Branch already checked out** → Remove existing worktree first: `git worktree remove <path>`

## Web Server Integration

Need to serve a worktree via local web server (LocalWP, nginx, etc)?

See [WEBSERVER-WORKTREES.md](WEBSERVER-WORKTREES.md) for swap/restore scripts that temporarily redirect your web server's document root.

## Troubleshooting

**Errors or unexpected behavior?** → See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

Common issues covered: broken symlinks, pre-commit hook failures, containerized environments.

## Examples

**User:** "I want to work on feature-auth while keeping my current work"
**Action:** Create worktree at `../gittree-feature-auth/`

**User:** "Set up a worktree for PR review of branch fix-login"
**Action:** Create worktree at `../gittree-fix-login/`

**User:** "I need to test two branches side by side"
**Action:** Create worktree for the second branch, both share dependencies
