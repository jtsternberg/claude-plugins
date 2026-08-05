---
name: create-git-tree
description: "Create git worktrees with symlinked vendor/node_modules for parallel branch work."
disable-model-invocation: true
---

# Git Tree

Create git worktrees in parallel directories with automatic symlinks to vendor, node_modules, and .env.

## Quick Reference

```bash
# Resolve this once. Codex: this path resolves under Claude Code; substitute the absolute
# path to this git-tree plugin root, which contains this skill's parent skills/ directory.
GIT_TREE_ROOT="${CLAUDE_PLUGIN_ROOT}"
"$GIT_TREE_ROOT/scripts/git-tree.sh" <branch-name> [--repo <path>] [--create]
```

## Workflow

Run the resolved script with the branch name. If no branch is provided, ask the user.

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
