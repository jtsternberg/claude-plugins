# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of Claude Code plugins (skills, commands, hooks) for sharing and reuse. Each plugin lives in its own directory under `plugins/`.

## Repository Structure

```
.claude-plugin/
├── plugin.json          # Plugin metadata
└── marketplace.json     # Marketplace registry of available plugins
plugins/
└── <plugin-name>/       # Each plugin in its own directory
    ├── manifest.json    # or .claude-plugin/plugin.json
    ├── hooks/           # Hook scripts (optional)
    └── commands/        # Slash command / skill markdown files (optional)
```

## Adding a New Plugin

1. Create a new directory under `plugins/<plugin-name>/`
2. Add required files (`manifest.json` or `.claude-plugin/plugin.json`, hooks, commands)
3. Register the plugin in `.claude-plugin/marketplace.json` by adding an entry to the `plugins` array
4. Update `README.md` with documentation for the new plugin

## Plugin Types

### Hook-based plugins
Hook scripts in `hooks/` that intercept Claude Code events (permissions, notifications, etc.) and return JSON decisions.

### Skill/Command-based plugins
Markdown files in `commands/` that define slash commands or skills Claude can invoke.

## Versioning

When making any changes to a plugin (skills, commands, hooks, metadata), always bump the version in its `.claude-plugin/plugin.json` before committing. Use semver: patch for fixes, minor for new features or non-breaking changes, major for breaking changes.

## Development Commands

```bash
# Install plugin locally for testing
claude plugins add /path/to/claude-plugins/plugins/<plugin-name>

# Test hook scripts directly (pipe JSON input)
echo '{"tool_name":"Bash","cwd":"/path","tool_input":{"command":"ls"}}' | bash plugins/<plugin-name>/hooks/<hook-script>.sh
```

---

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## General Rules

- **NEVER commit HANDOFF*.md files** - They are session artifacts only, not repo files

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd dolt push          # Push beads to Dolt remote
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->
