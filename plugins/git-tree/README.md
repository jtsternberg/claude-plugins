# Git Tree Plugin

Create git worktrees with symlinked dependencies for parallel branch work.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install git-tree@jtsternberg
```

## Description

Git Tree creates isolated worktrees in parallel directories with automatic symlinks to shared dependencies (vendor, node_modules, .env). Perfect for working on multiple branches simultaneously without losing your current work.

## Usage

The skill automatically triggers when you mention:
- "git worktree"
- "work on two branches"
- "parallel branch work"
- "review PR without switching"
- "keep my changes while checking out another branch"

### Direct Script Usage

```bash
SKILL_DIR="$HOME/.claude/skills/git-tree"
$SKILL_DIR/scripts/git-tree.sh <branch-name> [--repo <path>] [--create]
```

**Flags:**
- `--repo <path>`: Target repository (defaults to current directory)
- `--create`: Create branch if it doesn't exist

## Example

```
User: "I want to review PR #123 without losing my current changes"

Claude: Creates a worktree for the PR branch with symlinked dependencies,
        allowing you to test the PR while your main directory stays intact.
```

## Additional Documentation

- [SKILL.md](SKILL.md) - Complete skill documentation
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues and solutions
- [WEBSERVER-WORKTREES.md](WEBSERVER-WORKTREES.md) - Special considerations for web servers
- [REVIEW.md](REVIEW.md) - Skill review and design notes
