---
name: read-slack
description: "Read Slack messages from the terminal via the Slack Web API — fetch a full thread or message by URL, search messages across the workspace, or read a channel's recent history, all as clean plain text. Use this whenever the user pastes a Slack message/thread URL (slack.com/archives/…), asks to pull, read, fetch, quote, or investigate a Slack thread or conversation, wants context from Slack to feed into an investigation, or asks to search Slack for something — even if they don't name the API. Strongly prefer this over asking the user to copy/paste Slack content by hand, which is lossy and drops reply structure, timestamps, and links."
when_to_use: |
  Use when the user:
  - pastes a Slack URL (https://<workspace>.slack.com/archives/C…/p…) and wants its content
  - says "pull this Slack thread", "read this Slack conversation", "what did X say in Slack",
    "get me that thread", "grab the Slack discussion about Y", "quote this thread"
  - wants Slack context to investigate an issue/incident/customer question
  - asks to "search Slack for …" or "find the Slack message where …"
  - asks for a channel's recent messages
  Prefer this over hand-copied Slack text — the API preserves authors, timestamps,
  reply order, and links that copy/paste loses.
allowed-tools: "Bash(bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh *) Read"
---

# read-slack

Getting Slack context to Claude by copy/paste is slow and lossy — it drops reply structure, real timestamps, thread links, and edit markers, which is exactly the detail an investigation needs. This skill reads Slack directly through the Web API and prints clean text you can act on.

It is **read-only** and scoped to **your own visibility** — only the channels and DMs the token owner is already a member of. It cannot post, edit, or delete anything.

## Setup (one time)

The script needs a Slack **user token** (`xoxp-…`) and the `curl` + `jq` tools. If setup isn't done yet, see the plugin README (`../../README.md`) for the full walkthrough of creating the Slack app, requesting install approval, and minting the token. Provide the token one of two ways:

- `export SLACK_USER_TOKEN=xoxp-…`, or
- `export SLACK_TOKEN_OP_REF="op://Employee/Slack read-only/token"` (1Password ref; the script resolves it via `op read` so the token never lands in your shell env).

The token is passed to `curl` on stdin, never on the command line — it won't show up in `ps` or shell history.

## Verify it works

On first use — or whenever a call fails — run the check (it makes one `auth.test` call and prints the authenticated user/workspace). Don't run it on every invocation; once it passes for the session, trust it.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh --check
```

If it errors, the message says what's missing — usually the token isn't exported yet.

## Fetching a thread (the main use)

When the user gives a Slack message or thread URL, pass it straight through:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh thread 'https://acme.slack.com/archives/C08L6GH92R3/p1766517669357109?thread_ts=1763502924.627409&cid=C08L6GH92R3'
```

The URL carries the channel ID and timestamps, so nothing else is needed. If `thread_ts` is present the whole thread is returned; otherwise just that message. You can also pass a channel ID and a raw `ts` instead of a URL:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh thread C08L6GH92R3 1763502924.627409
```

Output is one block per message — author, local timestamp, then the message text with `<@U…>` mentions, `<#C…|chan>` channel refs, and `<url|label>` links unwrapped into readable form.

## Searching

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh search 'rate limit migration' 20
```

Uses `search.messages` (user-token only) and prints each match with its channel, author, timestamp, text, and a permalink you can hand back to the user. Slack search operators work inside the query, e.g. `search 'in:#lindris-onboarding 503 error'`.

## Channel history

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh history C08L6GH92R3 30
```

Prints the most recent messages (newest first) for a channel ID (or an `/archives/<id>` URL). Default limit is 20.

## Working with the output

The script writes to stdout. For a long thread you're about to reason over, redirect it to a file and read that, rather than pasting a wall of text into the conversation:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh thread '<url>' > /tmp/slack-thread.txt
```

Then Read `/tmp/slack-thread.txt`. This keeps the chat lean and gives you the complete, faithful thread to investigate from.

## Notes & limits

- **Visibility**: results are limited to what the token owner can see. A private channel you're not in returns nothing.
- **`search` needs `search:read`**, a user-token-only scope — a bot token can't search. This is why the setup uses an `xoxp-` user token.
- **Rate limits**: Slack tiers these methods; for very large threads the script requests up to 200 replies in one call, which covers almost everything. Extremely long threads may be truncated by Slack's paging (not currently followed).
- **Names**: user IDs are resolved to display names and cached per run. If a name shows as a raw `U…` ID, the token lacks `users:read` or the user is outside your visibility.
