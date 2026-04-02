# Paperclip

**A Claude Code skill for operating a locally-running Paperclip instance.**

Equips Claude with everything it needs to manage companies, agents, issues, and approvals via the `paperclipai` CLI — plus direct filesystem access to read and edit agent instruction files in real time.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install paperclip@jtsternberg
```

This registers the `paperclip` skill as a slash command in Claude Code.

---

## What It Does

### CLI Operations

Via the `paperclipai` CLI, Claude can:

- List and inspect companies and agents
- Create, update, checkout, and comment on issues
- Review and act on approvals (approve, reject, request revision)
- View activity logs and dashboard summaries
- Run diagnostics (`paperclipai doctor`)
- Start the server (`paperclipai run`)
- Manage auth and context profiles

### Agent File Editing

Paperclip stores agent instruction files directly on the filesystem:

```
~/.paperclip/instances/default/companies/<company-id>/agents/<agent-id>/instructions/
├── AGENTS.md     # Base identity and context
├── SOUL.md       # Persona and voice
├── HEARTBEAT.md  # Execution checklist
└── TOOLS.md      # Available tools and integrations
```

Claude can read and edit these files directly. **Changes reflect immediately in the UI — no restart needed.**

---

## Usage

Once installed, invoke the skill:

```
/paperclip
```

Then describe what you want to do. Examples:

> "List all open issues for the Acme company."

> "Read the SOUL.md for agent abc-123 in company xyz-456 and update its tone to be more concise."

> "Check system health and show me any auth issues."

> "Create an issue titled 'Fix the login flow' with high priority."

---

## Helper Scripts

The plugin includes two utility scripts:

**`scripts/inspect-agent.sh <company-id> <agent-id>`**
Dumps all four instruction files for an agent in one shot.

**`scripts/find-agent.sh`**
Lists every company and agent found on the filesystem, with a note on which instruction files exist for each.

Both scripts respect the `PAPERCLIP_DATA_DIR` environment variable if your instance lives somewhere other than `~/.paperclip/instances/default`.

---

## Prerequisites

- `paperclipai` CLI installed globally (`npm install -g paperclipai` or equivalent)
- A running Paperclip instance (default: `http://localhost:3100`)
- Authenticated session (`paperclipai auth login`) for API commands

---

## Notes

- All CLI commands support `--json` for machine-readable output — the skill uses this automatically.
- Agent-scoped API calls can use `--api-key <token>` to bypass board-user auth (get a key via `paperclipai agent local-cli`).
- The data directory can be overridden per-command with `-d <path>` or globally via `PAPERCLIP_DATA_DIR`.
- Worktree support: `paperclipai worktree:*` commands create isolated Paperclip instances per git worktree.
