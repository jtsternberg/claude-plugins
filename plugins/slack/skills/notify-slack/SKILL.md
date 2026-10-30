---
name: notify-slack
description: "Post a message to Slack from the terminal via an incoming webhook — a completion notification, a progress update, a result summary, or a Block Kit message. Covers 'ping me on Slack when this finishes', 'post that summary to Slack', 'send this to the team channel'."
when_to_use: |
  Use when the user wants something sent TO Slack:
  - "notify me on Slack when this is done", "ping the channel when the deploy finishes"
  - "post this summary to Slack", "send that to #eng"
  - "drop the results in Slack", "let the team know in Slack"
  Each configured webhook posts to one fixed channel chosen at install time —
  the payload cannot retarget it. Reading Slack is the companion `read-slack`
  skill; this one only writes.
allowed-tools: "Bash(bash */scripts/notify.sh *) Read"
---

# notify-slack

Sends a message into Slack through an **incoming webhook** — a single URL bound to one channel. That binding is the whole security model: the URL carries no account access, cannot read anything, cannot delete anything, and cannot post anywhere except the one channel its installer picked. It is the smallest possible grant for "let the agent tell me things in Slack".

The trade-off is that the destination is fixed. `channel`, `username`, and `icon` in the payload are **ignored** — Slack always uses the app's configuration. Several destinations means several webhooks (see `--to` below).

## Setup (one time)

The script needs a webhook URL and the `curl` + `jq` tools. The plugin README walks through it: create a Slack app, activate Incoming Webhooks, **Add New Webhook to Workspace**, pick the channel, copy the URL. That README is at `${CLAUDE_PLUGIN_ROOT}/README.md` — Codex: substitute the installed plugin directory for that token. Then store the URL under a name that says what the notifications are for:

- `export SLACK_WEBHOOK_URL_AGENT_NOTIFICATIONS=https://hooks.slack.com/services/…`, or
- `export SLACK_WEBHOOK_OP_REF_AGENT_NOTIFICATIONS="op://Employee/Slack notify/agent-notifications"` (1Password ref; the script resolves it via `op read` so the URL never sits in your shell env).

**Name every webhook for the role its notifications play, not for the channel behind it.** A webhook URL reveals nothing about where it posts, so the variable name is the only place that meaning lives — and a role name survives re-pointing the webhook at a different channel, which a channel name would not. `--to agent-notifications` reads `SLACK_WEBHOOK_URL_AGENT_NOTIFICATIONS` (uppercased, with `-` and `.` becoming `_`). `--to` refuses to fall back, so a name that doesn't resolve is an error rather than a message in the wrong place. The unsuffixed `SLACK_WEBHOOK_URL` works as a default when there is exactly one webhook, but it tells the next reader nothing.

**The URL is a bearer secret.** Anyone holding it can post to that channel, so it never goes in a repo, an issue, or a transcript — Slack actively searches for leaked webhook URLs and revokes them. The script hands it to `curl` on stdin, so it stays out of `ps` and shell history.

## Verify the config

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to agent-notifications --check
```

This validates deps and the URL **offline**. Incoming webhooks have no auth-check endpoint — the only way to prove a URL is still live is to post with it — so a passing `--check` does not promise delivery. Confirm that by sending one real message.

## Sending a message

**The message rides a file or stdin, not an argument.** Anything on the command line is visible in `ps` to every local user for as long as the process lives, and a notification routinely carries the thing you were working on — a log line, an error, a customer's name.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to agent-notifications --text-file /tmp/summary.md
```

Stdin works the same way, which suits a message you are composing in the same command:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
printf 'Deploy finished: 4 services green, 0 rollbacks.\n' \
  | bash "$SKILL_DIR/scripts/notify.sh" --to agent-notifications
```

A positional argument and `--text` also work, and are fine for a short fixed literal with nothing sensitive in it — `'nightly run started'`. Reach for the file or stdin form the moment the text contains anything you did not type yourself.

Whichever form you use, the text reaches `curl` through a file named in its stdin config, so it never appears in the *request's* argv — only your own invocation can leak it.

Slack's message markup is not Markdown — `*bold*` not `**bold**`, `<url|label>` not `[label](url)`, and no headings or tables. The full reference ships with the `collab-tools` plugin, in its `temp-draft` skill under `references/slack-formatting.md`; read it before composing anything with formatting in it.

Text is capped at 40,000 bytes (Slack's limit for a message's `text`). The script refuses longer input rather than letting Slack truncate it — post a summary with a link instead.

## The session link

Run from a Claude Code session with Remote Control on, every message ends with a link back to that session — `<https://claude.ai/code/session_…|Open Claude session>` on its own last line, or a trailing context block for a Block Kit message — so whoever reads the notification can open the conversation that sent it. The id comes from `$CLAUDE_CODE_BRIDGE_SESSION_ID`; outside Remote Control that is unset and no link is added. Text that already links the same session is left alone, so a caller with its own label keeps it. `--no-session-link` turns it off for one message.

A process detached from the session (a launchd job, a `nohup`'d watcher) does not inherit the variable, so its posts carry no link.

## More than one destination

One webhook, one channel — so reaching a second channel means a second webhook, named the same way:

```bash
export SLACK_WEBHOOK_URL_ALERTS=https://hooks.slack.com/services/…
export SLACK_WEBHOOK_URL_DEPLOYS=https://hooks.slack.com/services/…
```

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to alerts 'Disk at 91% on build-02.'
```

`--to` also accepts `SLACK_WEBHOOK_OP_REF_<NAME>` for a 1Password-held URL. When a `--to` name resolves to nothing the script stops — it never falls back to another webhook.

## Replying in a thread

A webhook post returns no timestamp, so the `ts` to reply under has to come from somewhere else — in this plugin, from the companion `read-slack` skill, whose `thread` and `history` output carries it.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to agent-notifications --thread-ts 1763502924.627409 'Fixed in 3ecbf8920.'
```

The parent message has to be in the webhook's own channel — the webhook cannot reach any other. A `ts` from elsewhere is not something Slack documents an error for, so verify the reply landed where you meant rather than trusting the `Sent to Slack` line alone.

## Block Kit messages

For richer layout, pass a JSON **array** of blocks. `--text` becomes the notification/fallback line, which is what shows in the sidebar and push notification — always supply it.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to agent-notifications --text 'Nightly suite: 2 failures' --blocks-file /tmp/blocks.json
```

## Sending is authorized by the request

**A request to notify is authorization to notify — send it.** "Ping me on Slack when this finishes", "post that summary", or an invocation of this skill authorizes both the message and the HTTPS call it needs. Do not ask whether to send, do not ask which channel when only one webhook is configured, and do not ask again once answered. The webhook reaches exactly one channel the operator chose at install time, which is the whole point of the grant.

Two facts to hold while composing, neither of them a reason to stop and ask:

- **A webhook post cannot be deleted** — incoming webhooks have no delete verb. So compose the message you mean; there is no edit afterwards.
- **`--dry-run` shows the exact payload and resolved destination** without sending. Use it when you want to see what would go out, and first when Slack answers `invalid_payload`.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/notify.sh" --to agent-notifications --dry-run --text-file /tmp/summary.md
```

A dry run is never a send. Report success only when the script prints `Sent to Slack.` — it says that only on HTTP 200 with a literal `ok` body.

## Deliberately not implemented

**No retry, no dedup journal, no receipt log.** A webhook post is one idempotent-enough HTTP call whose failures are all reported synchronously and nearly all permanent (revoked URL, archived channel, admin restriction) — retrying those just posts twice or fails twice. On the one ambiguous case, a network error mid-flight, the script says nothing was confirmed sent; check the channel rather than resending blind. Don't add exactly-once machinery here.

## When something fails

The script maps Slack's error strings to what to do about them — a revoked webhook, an archived channel, an admin restriction on this posting method. `no_service` after it previously worked usually means the URL leaked and Slack revoked it; regenerate it in the app's Incoming Webhooks settings rather than debugging the payload.
