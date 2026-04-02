# paperclipai CLI Cheatsheet

Quick reference for the most-used commands. All support `--json` for machine-readable output.

## Auth

| Command | What it does |
|---------|-------------|
| `paperclipai auth whoami` | Show current logged-in user |
| `paperclipai auth login` | Authenticate (interactive) |
| `paperclipai auth logout` | Remove stored credential |

## Discovery

| Command | What it does |
|---------|-------------|
| `paperclipai company list --json` | List all companies |
| `paperclipai agent list -C <id> --json` | List agents in a company |
| `paperclipai issue list -C <id> --json` | List all issues |
| `paperclipai issue list -C <id> --status todo,in_progress --json` | Open issues only |
| `paperclipai dashboard get -C <id> --json` | Company dashboard summary |
| `paperclipai activity list -C <id> --json` | Recent activity |

## Issues

| Command | What it does |
|---------|-------------|
| `paperclipai issue get <id-or-PC-N> --json` | Get issue details |
| `paperclipai issue create -C <id> --title "..." --description "..." --json` | Create issue |
| `paperclipai issue update <id> --status in_progress --json` | Update issue |
| `paperclipai issue checkout <id> --json` | Assign to agent |
| `paperclipai issue release <id> --json` | Release back to todo |
| `paperclipai issue comment <id> --json` | Add comment |

## Approvals

| Command | What it does |
|---------|-------------|
| `paperclipai approval list -C <id> --json` | List approvals |
| `paperclipai approval approve <id> --json` | Approve |
| `paperclipai approval reject <id> --json` | Reject |
| `paperclipai approval request-revision <id> --json` | Request changes |

## System

| Command | What it does |
|---------|-------------|
| `paperclipai doctor` | Run diagnostics |
| `paperclipai run` | Start server |
| `paperclipai context show` | Show active profile/context |
| `paperclipai context use <profile>` | Switch profile |

## Filesystem Paths

```
~/.paperclip/instances/default/companies/<company-id>/agents/<agent-id>/instructions/
├── AGENTS.md      # identity + context
├── SOUL.md        # persona + voice
├── HEARTBEAT.md   # execution checklist
└── TOOLS.md       # available tools
```

Environment variable override: `PAPERCLIP_DATA_DIR`
