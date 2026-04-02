# Paperclip Skill

Use this skill to operate a locally-running [Paperclip](https://paperclip.ing) instance as a power user or admin. Covers CLI operations via `paperclipai` and direct filesystem access to agent instruction files.

## Instance Layout

Paperclip stores instance data at `~/.paperclip/instances/default/` by default.

```
~/.paperclip/instances/default/
└── companies/
    └── <company-uuid>/
        └── agents/
            └── <agent-uuid>/
                └── instructions/
                    ├── AGENTS.md     # Base identity, context, capabilities
                    ├── SOUL.md       # Persona, voice, character
                    ├── HEARTBEAT.md  # Execution checklist, recurring tasks
                    └── TOOLS.md      # Available tools and integrations
```

**Instruction file purposes:**
- `AGENTS.md` — Who the agent is, what it knows, its core context
- `SOUL.md` — How the agent speaks and presents itself; persona/voice
- `HEARTBEAT.md` — Step-by-step checklist the agent follows on each cycle
- `TOOLS.md` — What tools/integrations the agent has access to

**Edits to these files reflect immediately in the UI — no restart needed.**

## Finding IDs

Company and agent IDs are UUIDs. Fastest way to find them:

```bash
# List all company IDs
ls ~/.paperclip/instances/default/companies/

# List agent IDs within a company
ls ~/.paperclip/instances/default/companies/<company-id>/agents/

# Cross-reference with CLI (after auth)
paperclipai company list --json
paperclipai agent list -C <company-id> --json
```

## Authentication

The instance runs in `authenticated` mode. CLI commands that call the API require a logged-in session:

```bash
# Check current auth status
paperclipai auth whoami

# Log in (interactive)
paperclipai auth login

# Log out
paperclipai auth logout
```

Agent-scoped API calls can bypass board-user auth using `--api-key <token>` (get a key via `paperclipai agent local-cli`).

## CLI Reference

### Companies

```bash
# List all companies
paperclipai company list --json

# Get one company
paperclipai company get <company-id> --json

# Export company to portable markdown
paperclipai company export <company-id>

# Import company package
paperclipai company import <path-or-url>
```

### Agents

```bash
# List agents for a company
paperclipai agent list -C <company-id> --json

# Get one agent
paperclipai agent get <agent-id> --json

# Set up local CLI access for an agent (creates API key, installs skills)
paperclipai agent local-cli <agent-id-or-ref>
```

### Issues

```bash
# List issues for a company (all statuses)
paperclipai issue list -C <company-id> --json

# Filter by status (todo, in_progress, done, cancelled, etc.)
paperclipai issue list -C <company-id> --status todo,in_progress --json

# Filter by assignee
paperclipai issue list -C <company-id> --assignee-agent-id <agent-id> --json

# Text search
paperclipai issue list -C <company-id> --match "keyword" --json

# Get a specific issue (by UUID or identifier like PC-12)
paperclipai issue get PC-12 --json
paperclipai issue get <issue-uuid> --json

# Create an issue
paperclipai issue create \
  -C <company-id> \
  --title "Issue title" \
  --description "Detailed description" \
  --status todo \
  --priority medium \
  --json

# Update an issue
paperclipai issue update <issue-id> \
  --status in_progress \
  --assignee-agent-id <agent-id> \
  --comment "Starting work on this" \
  --json

# Assign (checkout) an issue to an agent
paperclipai issue checkout <issue-id> --json

# Release issue back to todo
paperclipai issue release <issue-id> --json

# Add a comment
paperclipai issue comment <issue-id> --json
```

### Approvals

```bash
# List approvals for a company
paperclipai approval list -C <company-id> --json

# Get one approval
paperclipai approval get <approval-id> --json

# Approve / reject / request revision
paperclipai approval approve <approval-id> --json
paperclipai approval reject <approval-id> --json
paperclipai approval request-revision <approval-id> --json

# Resubmit an approval
paperclipai approval resubmit <approval-id> --json
```

### Activity

```bash
# List recent activity for a company
paperclipai activity list -C <company-id> --json
```

### Dashboard

```bash
# Get summary dashboard for a company
paperclipai dashboard get -C <company-id> --json
```

### System / Ops

```bash
# Run diagnostic checks
paperclipai doctor

# Start the server (bootstraps if needed)
paperclipai run

# Print env vars for deployment
paperclipai env

# Update configuration
paperclipai configure
```

### Context Profiles

```bash
# Show current context
paperclipai context show

# List profiles
paperclipai context list

# Switch profile
paperclipai context use <profile-name>

# Set a value on current profile
paperclipai context set --api-base http://localhost:3100
```

## Common Workflows

### Inspect an Agent

```bash
COMPANY_ID="<company-uuid>"
AGENT_ID="<agent-uuid>"
BASE="$HOME/.paperclip/instances/default/companies/$COMPANY_ID/agents/$AGENT_ID/instructions"

cat "$BASE/AGENTS.md"
cat "$BASE/SOUL.md"
cat "$BASE/HEARTBEAT.md"
cat "$BASE/TOOLS.md"
```

Or use the helper script:

```bash
bash plugins/paperclip/scripts/inspect-agent.sh <company-id> <agent-id>
```

### Update an Agent Persona

Edit `SOUL.md` or `AGENTS.md` directly — changes are live immediately:

```bash
AGENT_DIR="$HOME/.paperclip/instances/default/companies/<company-id>/agents/<agent-id>/instructions"
# Read current state, then edit in place
cat "$AGENT_DIR/SOUL.md"
```

### Check System Health

```bash
paperclipai doctor
paperclipai auth whoami
```

### List Open Issues for a Company

```bash
paperclipai issue list -C <company-id> --status todo,in_progress --json
```

### Create an Issue

```bash
paperclipai issue create \
  -C <company-id> \
  --title "What needs to be done" \
  --description "Context and details" \
  --status todo \
  --priority medium \
  --json
```

### Full Discovery: Find a Company and Its Agents

```bash
# Step 1: list company IDs from filesystem
ls ~/.paperclip/instances/default/companies/

# Step 2: get company details
paperclipai company list --json

# Step 3: list agents
paperclipai agent list -C <company-id> --json

# Step 4: explore agent files
ls ~/.paperclip/instances/default/companies/<company-id>/agents/<agent-id>/instructions/
```

## Notes

- The local instance runs at `http://localhost:3100` by default.
- Always use `--json` when processing CLI output programmatically.
- The `--api-key` flag enables agent-scoped API calls without board-user auth.
- Worktree commands (`paperclipai worktree:*`) create isolated Paperclip instances per git worktree.
- Data directory can be overridden with `-d <path>` or `--data-dir <path>` on any command.
