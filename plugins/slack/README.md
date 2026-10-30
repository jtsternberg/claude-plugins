# slack

Slack from the terminal, exposed to Claude as two skills that stay deliberately separate:

| Skill | Direction | Grant |
|-------|-----------|-------|
| **`read-slack`** | Slack → Claude | A user token with read scopes. Sees what you see; cannot post, edit, or delete. |
| **`notify-slack`** | Claude → Slack | An incoming webhook URL. Posts to **one** channel; cannot read anything. |

They use different credentials on purpose. Neither one can do the other's job, so a leak of either is bounded — the read token can't write, and the webhook URL can't read.

Both need `curl` and `jq` on `PATH`, and both optionally read their credential from 1Password via the `op` CLI instead of an env var.

---

## `read-slack` — pulling Slack into Claude

Fetch a full thread or message by URL, search messages across the workspace, or read a channel's recent history — printed as clean plain text, so Slack context reaches Claude without lossy copy/paste.

Read-only and scoped to the token owner's own visibility (channels/DMs they're already in).

### What you need

A Slack **user token** (`xoxp-…`) with read scopes, created via a small Slack app you own.

### Creating the Slack app + token

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

### Verify

```bash
bash skills/read-slack/scripts/slack.sh --check
```

Prints the authenticated user + workspace, or tells you exactly what's missing.

### Usage

```bash
# Full thread from a pasted Slack URL
skills/read-slack/scripts/slack.sh thread 'https://acme.slack.com/archives/C0…/p17665…?thread_ts=1763…&cid=C0…'

# Search (Slack search operators work inside the query)
skills/read-slack/scripts/slack.sh search 'in:#onboarding 503 error' 20

# A channel's recent messages
skills/read-slack/scripts/slack.sh history C08L6GH92R3 30
```

Once the plugin is installed you don't invoke the script by hand — just paste a Slack URL or ask Claude to pull/search a thread and the `read-slack` skill runs it for you.

---

## `notify-slack` — posting from Claude into Slack

Send a completion notification, a progress update, a result summary, or a Block Kit message into a Slack channel.

### Why a webhook and not a write scope

Adding `chat:write` to the read app would mean a fresh install and admin re-approval, a re-issued token (breaking the read path until you update it), and a credential that can post as you, anywhere you can. An **incoming webhook** is a far smaller grant: a single URL, bound at install time to one channel, that can do nothing but post there. It carries no account access and cannot read a thing.

The cost of that smallness is that the destination is fixed. `channel`, `username`, and `icon` in the payload are ignored — Slack always uses the app's own configuration. More channels means more webhooks.

### Creating the webhook

1. **Create a Slack app** (or reuse one) at <https://api.slack.com/apps> → **Create New App** → **From scratch**. A separate app from the read-only one is cleaner: it keeps the read app's zero-write-scopes property intact, and either credential can be revoked without touching the other.

2. **Activate Incoming Webhooks.** In the app, open **Incoming Webhooks** and toggle **Activate Incoming Webhooks** on.

3. **Add New Webhook to Workspace.** Click it, pick the destination channel, and **Authorize**. This is a self-contained mini install flow — no server, no OAuth redirect to build. To use a **private** channel you must already be a member of it.

4. **Copy the URL** from **Webhook URLs for Your Workspace**. It has the shape `https://hooks.slack.com/services/<team>/<hook>/<secret>`.

   While you're in the app settings, `assets/claude-notify.png` in this plugin is an app icon you can upload under **Display Information → App icon** (1254×1254, comfortably over Slack's 512 minimum) — a paper plane on `#2C2D30`, the background colour Slack defaults that page to, so the icon tile and the app banner read as one piece. `assets/claude-notify.svg` is the vector source if you want to recolour it or export another size.

5. **Store it under a name that says what the notifications are for.** Either:
   - `export SLACK_WEBHOOK_URL_AGENT_NOTIFICATIONS=https://hooks.slack.com/services/…`, **or**
   - `export SLACK_WEBHOOK_OP_REF_AGENT_NOTIFICATIONS="op://Employee/Slack notify/agent-notifications"` (resolved via `op read` at call time).

   Name it for the role the notifications play, not the channel behind it: a webhook URL reveals nothing about where it posts, and the channel can be re-pointed while the role stays put. `--to agent-notifications` reads `SLACK_WEBHOOK_URL_AGENT_NOTIFICATIONS` — uppercased, with `-` and `.` becoming `_`. The unsuffixed `SLACK_WEBHOOK_URL` works as a default when there is only one webhook, but it tells the next reader nothing.

> **The URL is the credential.** Anyone holding it can post to that channel. Never put it in a repo, an issue, a PR, or a transcript — Slack actively searches for leaked webhook URLs and revokes the ones it finds. If a send starts failing with `no_service` after previously working, assume that's what happened and regenerate it.

### Verify

```bash
bash skills/notify-slack/scripts/notify.sh --to agent-notifications --check
```

Validates deps and the URL **without sending anything**, and prints the endpoint with its secret tail withheld. Incoming webhooks have no auth-check endpoint, so a pass doesn't prove the URL is still live — send one real message to confirm that.

### Usage

```bash
# The default: message from a file, so it stays out of `ps`
skills/notify-slack/scripts/notify.sh --to agent-notifications --text-file /tmp/summary.md

# Or from stdin
printf 'Deploy finished: 4 services green.\n' | skills/notify-slack/scripts/notify.sh --to agent-notifications

# A short fixed literal may ride argv — nothing sensitive, nothing you didn't type
skills/notify-slack/scripts/notify.sh --to agent-notifications 'nightly run started'

# Inspect the exact payload and destination without sending
skills/notify-slack/scripts/notify.sh --to agent-notifications --dry-run --text-file /tmp/summary.md

# Reply in a thread (get the ts from read-slack)
skills/notify-slack/scripts/notify.sh --to agent-notifications --thread-ts 1763502924.627409 'Fixed in 3ecbf8920.'

# Block Kit layout; --text is the notification fallback line
skills/notify-slack/scripts/notify.sh --to agent-notifications --text 'Nightly suite: 2 failures' --blocks-file /tmp/blocks.json
```

Slack's markup is not Markdown (`*bold*`, `<url|label>`, no headings or tables). The `collab-tools` plugin's `temp-draft` skill carries the full reference at `skills/temp-draft/references/slack-formatting.md`.

Text is capped at 40,000 bytes — Slack's limit for a message's `text`. The script refuses longer input rather than letting Slack truncate it.

From a Claude Code session with Remote Control on, each message ends with an `Open Claude session` link back to that session (read from `$CLAUDE_CODE_BRIDGE_SESSION_ID`). It is skipped when the variable is unset, when the text already links the same session, or with `--no-session-link`.

### More than one channel

One webhook, one channel — a second channel means a second webhook, named the same way:

```bash
export SLACK_WEBHOOK_URL_ALERTS=https://hooks.slack.com/services/…
export SLACK_WEBHOOK_URL_DEPLOYS=https://hooks.slack.com/services/…
```

```bash
skills/notify-slack/scripts/notify.sh --to alerts 'Disk at 91% on build-02.'
```

`--to` never falls back to another webhook — a typo'd name is an error, not a message in the wrong channel.

### No retries, no receipts

The script posts once. Webhook failures are reported synchronously and nearly all of them are permanent — a revoked URL, an archived channel, an admin restriction — so retrying either double-posts or fails twice. On the one genuinely ambiguous outcome, a network error mid-flight, it says nothing was confirmed sent; check the channel rather than resending. There is deliberately no dedup journal here.

Incoming webhooks also cannot delete a message once posted. Treat every send as final.

---

## Security notes

- **Credentials never touch argv.** Both scripts hand their secret to `curl` via stdin (`--config -`), so neither the user token nor the webhook URL appears in `ps` or shell history.
- **`notify-slack` refuses any URL that isn't `https://hooks.slack.com/…`**, so a mistyped host can't be handed the secret.
- **The read app is read-only by construction** — no write scopes, no bot user. Even if that token leaked it could only *read* what its owner can already see. Rotate it anyway (Slack app → OAuth & Permissions → regenerate) if it's ever exposed.
- **The webhook is write-only by construction** — it cannot read, cannot list, cannot leave the channel it was installed into. Rotate it in the app's **Incoming Webhooks** settings if exposed.
