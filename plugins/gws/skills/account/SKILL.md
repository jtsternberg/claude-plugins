---
name: gws-account
description: Check, add, list, or switch the active Google account. This skill is the ONLY way to manage Google accounts — there is no standalone CLI command for account management.
when_to_use: |
  Use when the user asks anything about Google accounts: "which google account am I using?",
  "switch google account", "add google account", "what account is active?",
  "list google accounts", "gws account", "change to my work account",
  "am I logged in to Google?", "check my Google auth".
  IMPORTANT: The gws CLI does NOT have an "account" subcommand — this skill provides
  all account management. Do not attempt to run gws account commands directly.
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

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-switch.sh <label>
```

This persists the choice to `~/.config/gws-accounts/.active`. All
subsequent account-aware scripts will use that account. To switch
back to the default account:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/account-switch.sh default
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
`~/.config/gws`). By maintaining separate config directories per account
label under `~/.config/gws-accounts/<label>/`, we can switch between accounts.

The active account is tracked in `~/.config/gws-accounts/.active` (a
single-line file containing the label). When this file is absent, the
default account (`~/.config/gws`) is used. This persists across shell
sessions and agent `Bash()` calls.

Each account directory contains:
- `client_secret.json` — OAuth app config (copied from default, shared across accounts)
- `credentials.enc` — encrypted OAuth credentials (per-account)
- `token_cache.json` — cached access token (per-account)
- `account.json` — metadata with label and email (for listing)

## Integration with Other Skills

When using `gdoc-to-md` or `md-to-gdoc` with a doc/folder that belongs to
a different account, switch first then run the command:

1. Switch: `account-switch.sh work`
2. Then run the download/upload command

## Troubleshooting

**"No accounts configured":** Run the add subcommand with a label to set up
your first account.
**Browser doesn't open:** The script captures the OAuth URL and opens it
automatically with `open` (macOS) or `xdg-open` (Linux). If neither works,
the URL is printed to stderr for manual opening.
**Account exists error:** To re-authenticate an existing account, remove its
directory at `~/.config/gws-accounts/<label>/` and add it again.
