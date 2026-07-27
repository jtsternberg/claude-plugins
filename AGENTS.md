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
└── <plugin-name>/               # Each plugin in its own directory
    ├── .claude-plugin/
    │   └── plugin.json          # Plugin metadata (keep at the plugin root)
    ├── README.md                # Plugin-level docs
    ├── skills/                  # Skills live here (optional)
    │   └── <skill-name>/        # One directory per skill
    │       ├── SKILL.md         # The skill definition — belongs at this path
    │       └── scripts/         # Scripts the skill runs, bundled with it
    ├── commands/                # Slash command markdown files (optional)
    └── hooks/                   # Hook scripts (optional)
```

Each skill's `SKILL.md` belongs at `plugins/<plugin-name>/skills/<skill-name>/SKILL.md`. That path is what makes the skill discoverable in autocomplete and invocable as `$<skill-name>`. Keep `.claude-plugin/plugin.json` at the plugin root; everything a skill needs (its `SKILL.md` and any `scripts/`) sits together under its own `skills/<skill-name>/` directory.

When a skill runs bundled scripts, reference them through the runtime-resolved skill path so they work from any working directory:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/<script-name> [args]
```

Use `${CLAUDE_SKILL_DIR}/scripts/…` in `SKILL.md` (and in the skill's `allowed-tools` frontmatter). This anchors each call to the installed skill directory, so it resolves whether the skill fires from the repo, an install cache, or a user's unrelated project. See `plugins/research-tools/skills/fetch-docs/SKILL.md` for a working example.

## Adding a New Plugin

1. Create a new directory under `plugins/<plugin-name>/`
2. Put `plugin.json` at `plugins/<plugin-name>/.claude-plugin/plugin.json`
3. For each skill, create `plugins/<plugin-name>/skills/<skill-name>/SKILL.md`, and bundle any scripts it runs in that same `skills/<skill-name>/scripts/` directory
4. Add hooks (`hooks/`) and slash commands (`commands/`) at the plugin root as needed
5. Register the plugin in `.claude-plugin/marketplace.json` by adding an entry to the `plugins` array
6. Update `README.md` with documentation for the new plugin

To confirm a new skill sits where discovery expects it, check that it matches the others:

```bash
find plugins -name SKILL.md    # every result should be plugins/<plugin>/skills/<skill>/SKILL.md
```

## Plugin Types

### Hook-based plugins
Hook scripts in `hooks/` that intercept Claude Code events (permissions, notifications, etc.) and return JSON decisions.

### Skill-based plugins
Each skill is a `SKILL.md` at `skills/<skill-name>/SKILL.md`, with its scripts bundled in `skills/<skill-name>/scripts/` and referenced via `${CLAUDE_SKILL_DIR}/scripts/…`. This layout is what surfaces the skill in autocomplete and lets Claude invoke it as `$<skill-name>`.

### Command-based plugins
Markdown files in `commands/` that define slash commands Claude can invoke.

## Versioning

When making any changes to a plugin (skills, commands, hooks, metadata), always bump the version in its `.claude-plugin/plugin.json` before committing. Use semver: patch for fixes, minor for new features or non-breaking changes, major for breaking changes.

## Development Commands

```bash
# Install plugin locally for testing
claude plugins add /path/to/claude-plugins/plugins/<plugin-name>

# Test hook scripts directly (pipe JSON input)
echo '{"tool_name":"Bash","cwd":"/path","tool_input":{"command":"ls"}}' | bash plugins/<plugin-name>/hooks/<hook-script>.sh
```

## Testing

One command runs every suite in the repo, across all three languages:

```bash
bash tests/run-all.sh
```

It exits 0 only when every suite that *could* run passed. A suite whose runtime is
missing (no `cmux`, no `pytest`) is reported as **SKIP**, never silently passed — so
read the summary, not just the exit code.

CI (`.github/workflows/tests.yml`) runs exactly that script on pushes to `main`, on
pull requests, and on manual dispatch. It runs on **ubuntu-latest** on purpose: these
suites also have to keep working on the Linux box, and cmux-dependent suites self-skip
there.

### Put a new suite where the runner will find it

Suites are **discovered by glob, not listed** — a hardcoded list silently omits new
tests, which is exactly how the handoff plugin shipped 14 passing tests that CI never
ran. Match one of these paths and it is covered automatically:

| Language | Path | Runner |
|---|---|---|
| bash | `plugins/<plugin>/tests/<name>_test.sh` | `bash` |
| node | `plugins/<plugin>/skills/<skill>/tests/<name>.test.mjs` | `node --test` |
| node | `plugins/<plugin>/tests/<name>.test.mjs` | `node --test` |
| python (stdlib) | `plugins/<plugin>/skills/<skill>/tests/test_*.py` | `unittest discover` |
| python (pytest) | `plugins/gws/skills/*/tests/` | `pytest` |

Bash suites should print `N passed, M failed` and exit non-zero on failure. If a suite
needs a tool that may be absent, self-skip with exit 0 and say so on stdout.

Anything that reaches a real database, a real API, or `cmux` must be stubbed — the
handoff suite stubs `bd` via `PATH`. Tests must never touch a real beads database.

### The parser drift guard

`tests/parser-drift.test.mjs` asserts that `session-tools`' `lib/transcript.mjs` (the
source of truth for reading Claude Code transcripts) and `hotline`'s
`switchboard/scripts/server.js` still agree on what counts as harness noise and what a
compaction boundary looks like. They silently diverged twice before this existed. If you
change transcript-parsing behavior in either, expect this to fail — and fix both.

Read its header before adding a third implementation to the comparison: the jq and
Python readers are excluded deliberately, and the reasons are documented there.

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
2. **Run quality gates** (if code changed) - `bash tests/run-all.sh` (see [Testing](#testing)); check the summary for SKIPs, not just the exit code
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
