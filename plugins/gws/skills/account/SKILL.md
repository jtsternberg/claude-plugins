---
name: gws-account
description: "Check, add, list, or switch the active Google account. This skill is the ONLY way to manage Google accounts — there is no standalone CLI command for account management."
when_to_use: |
  Use when the user asks anything about Google accounts: "which google account am I using?",
  "switch google account", "add google account", "what account is active?",
  "list google accounts", "gws account", "change to my work account",
  "am I logged in to Google?", "check my Google auth".
  IMPORTANT: The gws CLI does NOT have an "account" subcommand — this skill provides
  all account management. Do not attempt to run gws account commands directly.
argument-hint: "<add|list|switch|current> [label] [--json]"
allowed-tools: "Bash(bash *) Bash(gws *) Bash(python3 *)"
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

## Before You Write Anything: `--json` Is the Body, `--params` Is the URL

This bites every agent exactly once, and it fails **silently with exit 0**. If you
are about to run a `gws` write (`create`, `insert`, `update`, `patch`), read this.

- `--params` → URL/query and path parameters only (`fileId`, `userId`, `fields`)
- `--json` → the request body (`name`, `mimeType`, `parents`, `trashed`, …)

Put body fields in `--params` and the CLI drops every one of them, returns exit 0,
and hands back a well-formed resource — so nothing looks wrong:

```bash
# WRONG — creates an "Untitled" application/octet-stream file in My Drive root
gws drive files create --params '{"name":"7.28.26","mimeType":"application/vnd.google-apps.folder","parents":["FOLDER_ID"]}'
# → {"id":"1bv5...","name":"Untitled","mimeType":"application/octet-stream"}

# RIGHT
gws drive files create --json '{"name":"7.28.26","mimeType":"application/vnd.google-apps.folder","parents":["FOLDER_ID"]}'
# → {"id":"1bQL...","name":"7.28.26","mimeType":"application/vnd.google-apps.folder"}
```

The only warning you get is a misleading one — `parameter 'parents' is not marked as
repeated` — which describes array encoding, not the actual mistake. **Treat that
warning on a write as "you meant `--json`."**

**Always `--dry-run` a write first.** It prints the split explicitly, so the mistake
is visible before it fires:

```bash
gws drive files create --dry-run --json '{"name":"x","mimeType":"application/vnd.google-apps.folder","parents":["ID"]}'
# → {"body":{"mimeType":"...","name":"x","parents":["ID"]},"query_params":[],"url":"..."}
#      ^^^^ body populated, query_params empty = correct.
#      With --params it's the reverse: empty body, and the write silently no-ops.
```

Then verify what came back matches what you sent — `name` and `mimeType` in the
response are the tell. A returned ID does **not** mean the fields landed.

Why the habit forms: reads legitimately take `--params`, because their arguments
really are query params (`gws drive files list --params '{"q":"..."}'`,
`gws drive files get --params '{"fileId":"..."}'`). By your first write, `--params`
is muscle memory.

Related papercut: `gws schema` takes a **dotted** path, not subcommands —
`gws schema drive.files.create`, not `gws schema drive files create`. Use it to
check whether a given key is a query param (`"location": "query"`) or a body field.

## Integration with Other Skills

When using `google-doc-to-md` or `md-to-google-doc` with a doc/folder that belongs to
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
