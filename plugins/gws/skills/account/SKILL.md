---
name: gws-account
description: Manage multiple Google accounts for gws CLI. Add, list, switch between, and check active Google Workspace accounts. Triggers on "switch google account", "add google account", "which google account", "gws account", "list accounts".
argument-hint: <add|list|switch|current> [label] [--json]
allowed-tools: Bash(bash *) Bash(gws *) Bash(python3 *)
---

# Google Account Manager

Manage multiple Google accounts for use with the `gws` CLI. Each account
is stored in its own config directory under `~/.config/gws-accounts/<label>/`.

## Prerequisites

```!
gws auth status 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Authenticated as: {d.get(\"user\",\"unknown\")}')" 2>/dev/null || echo "NOT AUTHENTICATED — run: gws auth login"
```

## Task

Parse the user's request to determine which subcommand to run, then execute
the appropriate script.

### Add a new account

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-add.sh <label>
```

This opens a browser for OAuth login. The `<label>` is a short name like
`work` or `personal`. The user must complete the browser auth flow.

**Important:** This is interactive — warn the user that a browser window
will open and they need to complete the login.

### List all accounts

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-list.sh
```

For programmatic use:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-list.sh --json
```

### Switch active account

To switch for subsequent gws commands in this session:

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/account-switch.sh <label>)"
```

This sets `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` to the labeled account's
config directory. All subsequent `gws` commands in this shell session
will use that account.

For programmatic use (just get the config dir path):

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-switch.sh <label> --env
```

### Check current account

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-current.sh
```

For programmatic use:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-current.sh --json
```

Just the email:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-current.sh --email
```

## How It Works

The `gws` CLI stores all auth state in a config directory (default:
`~/.config/gws`). The `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` environment variable
overrides this. By maintaining separate config directories per account label,
we can switch between accounts by changing this env var.

Each account directory contains:
- `client_secret.json` — OAuth app config (copied from default, shared across accounts)
- `credentials.enc` — encrypted OAuth credentials (per-account)
- `token_cache.json` — cached access token (per-account)
- `account.json` — metadata with label and email (for listing)

## Integration with Other Skills

When using `gdoc-to-md` or `md-to-gdoc` with a doc/folder that belongs to
a different account, the error message will tell you which account you're
authenticated as and suggest switching. To use a specific account:

1. Switch first: `eval "$(account-switch.sh work)"`
2. Then run the download/upload command

Or inline for a single command:

```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$(bash ${CLAUDE_SKILL_DIR}/../../scripts/account-switch.sh work --env) gws drive files list
```

## Troubleshooting

**"No accounts configured":** Run the add subcommand with a label to set up
your first account.
**Browser doesn't open:** The `gws auth login` command opens a browser for
OAuth. If it doesn't open automatically, look for a URL printed to stderr.
**Account exists error:** To re-authenticate an existing account, remove its
directory at `~/.config/gws-accounts/<label>/` and add it again.
