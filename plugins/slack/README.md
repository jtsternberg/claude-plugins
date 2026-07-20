# slack

Read-only Slack access from the terminal, exposed to Claude as the **`read-slack`** skill. Fetch a full thread or message by URL, search messages across the workspace, or read a channel's recent history — printed as clean plain text so Slack context can be handed to Claude without lossy copy/paste.

Read-only and scoped to the token owner's own visibility (channels/DMs they're already in). It cannot post, edit, or delete.

## What you need

- `curl` and `jq` on `PATH`.
- A Slack **user token** (`xoxp-…`) with read scopes — created via a small Slack app you own (below).
- Optional: the 1Password CLI (`op`) if you want to store the token there instead of an env var.

## Creating the Slack app + token

Slack's Web API needs a token tied to an app. A **user token** (not a bot token) is required because message search (`search.messages`) only works with user tokens. Here's the full flow:

1. **Create the app.** Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**. Name it (e.g. "read-only") and pick your workspace.

2. **Add User Token Scopes.** In the app, open **OAuth & Permissions** → scroll to **User Token Scopes** (*not* Bot Token Scopes) and add:

   | Scope | Enables |
   |-------|---------|
   | `search:read` | `search.messages` — searching (user-token only) |
   | `channels:history` | read public-channel messages |
   | `groups:history` | read private-channel messages you're in |
   | `im:history` | read your DMs |
   | `mpim:history` | read group DMs |
   | `channels:read` | resolve public channel IDs ↔ names |
   | `groups:read` | resolve private channel IDs |
   | `users:read` | resolve user IDs → display names |

   Leave **Bot Token Scopes**, Event Subscriptions, Interactivity, Slash Commands, and Redirect URLs empty — this app never runs a server and never writes. Fewer scopes = easier approval.

   > **Get all scopes right before installing.** Adding a scope later forces a fresh install/approval and re-issues the token.

3. **Install to the workspace.** Still on **OAuth & Permissions**, click **Install to Workspace** (or **Request to Workspace Install** if your workspace requires admin approval — many do). On a workspace you administer (e.g. a personal one) this is instant; on a managed org an admin must approve the request. The **Reason** field is your pitch to the admin — describe it honestly as a personal, read-only tool.

4. **Copy the token.** After install, the **User OAuth Token** (`xoxp-…`) appears on that same page.

5. **Store it.** Either:
   - `export SLACK_USER_TOKEN=xoxp-…` in your shell profile, **or**
   - put it in 1Password and point the skill at it:
     `export SLACK_TOKEN_OP_REF="op://Employee/Slack read-only/token"`
     (the script resolves it via `op read` at call time, so the token never sits in your environment).

> If you later add a scope, you must click **Reinstall** — Slack does not grant new scopes to an existing token automatically.

## Verify

```bash
bash skills/read-slack/scripts/slack.sh --check
```

Prints the authenticated user + workspace, or tells you exactly what's missing.

## Usage

```bash
# Full thread from a pasted Slack URL
skills/read-slack/scripts/slack.sh thread 'https://acme.slack.com/archives/C0…/p17665…?thread_ts=1763…&cid=C0…'

# Search (Slack search operators work inside the query)
skills/read-slack/scripts/slack.sh search 'in:#onboarding 503 error' 20

# A channel's recent messages
skills/read-slack/scripts/slack.sh history C08L6GH92R3 30
```

Once the plugin is installed, you don't invoke the script by hand — just paste a Slack URL or ask Claude to pull/search a thread and the `read-slack` skill runs it for you.

## Security notes

- The token is passed to `curl` via stdin (`--config -`), so it never appears in `ps`/argv or shell history.
- The app is read-only by construction (no write scopes, no bot user). Even if the token leaked, it could only *read* what its owner can already see — but rotate it anyway (Slack app → OAuth & Permissions → regenerate) if it's ever exposed.
