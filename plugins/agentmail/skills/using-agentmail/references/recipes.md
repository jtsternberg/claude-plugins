# Recipes: multi-step AgentMail workflows

Worked round trips. Every flag here still needs confirming against
`agentmail <resource> <cmd> --help` — these show the *shape* of a workflow, not a frozen
flag contract.

All of them assume `AGENTMAIL_API_KEY` is set and the preflight passed.

## 1. First round trip

Prove send *and* receive work before building anything on top.

```bash
# Which inbox am I sending from?
agentmail inboxes list --format json > /tmp/am-inboxes.json
jq -r '.inboxes[] | .inbox_id' /tmp/am-inboxes.json
INBOX="my-agent@agentmail.to"

# Send to the human's own signup address — the only recipient that works on an
# unverified org, and therefore the right smoke test.
# CONFIRM WITH THE USER FIRST. This command prompts for permission by design.
agentmail inboxes:messages send \
  --inbox-id "$INBOX" \
  --to you@example.com \
  --subject "AgentMail smoke test" \
  --text "If you can read this, sending works." \
  --format json > /tmp/am-sent.json

jq -r '.message_id, .thread_id' /tmp/am-sent.json

# Now the receive half: reply from your own mail client, then poll.
agentmail inboxes:messages list --inbox-id "$INBOX" --limit 5 --format json > /tmp/am-msgs.json
jq -r '.messages[] | "\(.message_id)\t\(.subject)"' /tmp/am-msgs.json
```

If the reply does not show up, before assuming delivery failed:

```bash
agentmail inboxes:messages list --inbox-id "$INBOX" --limit 10 \
  --include-spam --include-unauthenticated --include-blocked --include-trash \
  --format json > /tmp/am-msgs-all.json
```

Inbound mail with missing auth headers gets the `unauthenticated` label rather than being
dropped, and `list` hides it by default.

## 2. Triage loop — process new mail exactly once

There is no mark-as-read endpoint. Labels are the state machine, and this is the standard
guard against reprocessing.

```bash
INBOX="my-agent@agentmail.to"

# Only what hasn't been handled.
agentmail inboxes:messages list --inbox-id "$INBOX" --label unread --format json \
  > /tmp/am-unread.json

# For each message: read the NEW content, not the quoted chain.
MSG=$(jq -r '.messages[0].message_id' /tmp/am-unread.json)
agentmail inboxes:messages get --inbox-id "$INBOX" --message-id "$MSG" --format json \
  > /tmp/am-msg.json
jq -r '.extracted_text // .text // .html' /tmp/am-msg.json

# ... decide what to do ...

# Then flip the state so a restart doesn't reprocess it.
agentmail inboxes:messages update --inbox-id "$INBOX" --message-id "$MSG" \
  --add-labels processed --remove-labels unread
```

`extracted_text` / `extracted_html` strip quoted history. Note the fallback order:
`extracted_text` → `text` → `html`. Do not assume `text` exists — Gmail and Outlook
forwards are often HTML-only, so `text` and `preview` can both be absent.

## 3. Reply with human review (the default for anything non-trivial)

Draft first, show it, then send. `--client-id` makes the create idempotent, so a retried
create cannot produce two drafts.

```bash
INBOX="my-agent@agentmail.to"
MSG="<abc123@agentmail.to>"

# A reply draft derives recipients, subject, and threading from the source message.
agentmail inboxes:drafts create \
  --inbox-id "$INBOX" \
  --in-reply-to "$MSG" \
  --client-id "reply-to-abc123" \
  --text "Thanks — I'll have an answer by Thursday." \
  --format json > /tmp/am-draft.json

DRAFT=$(jq -r '.draft_id' /tmp/am-draft.json)

# Show the user exactly what will go out.
agentmail inboxes:drafts get --inbox-id "$INBOX" --draft-id "$DRAFT" --format pretty

# Only after they approve:
agentmail inboxes:drafts send --inbox-id "$INBOX" --draft-id "$DRAFT"
```

To reply to the whole thread instead of just the sender, add `--reply-all` to the
*create* — and note you then cannot pass `--to`, `--cc`, or `--bcc`. Read the thread first
and tell the user the recipient count; the cap is 50 across `to`+`cc`+`bcc`.

A draft's kind is fixed at creation: you cannot turn a plain draft into a reply. Create a
new one.

## 4. Read a whole conversation

```bash
INBOX="my-agent@agentmail.to"

agentmail inboxes:threads list --inbox-id "$INBOX" --limit 10 --format json > /tmp/am-threads.json
jq -r '.threads[] | "\(.thread_id)\t\(.subject)"' /tmp/am-threads.json

THREAD=$(jq -r '.threads[0].thread_id' /tmp/am-threads.json)
agentmail inboxes:threads get --inbox-id "$INBOX" --thread-id "$THREAD" --format json \
  > /tmp/am-thread.json
jq -r '.messages[] | "── \(.from) ──\n\(.extracted_text // .text // "(no text part)")\n"' /tmp/am-thread.json
```

The usual next move is to reply to the **last** message in the thread, not the first.

## 5. Search

```bash
# Relevance-ranked full text, one inbox. `limit` cannot exceed 100.
agentmail inboxes:messages search --inbox-id "$INBOX" --q "invoice overdue" --format json

# Org-wide across every inbox.
agentmail threads search --q "invoice overdue" --format json
```

For an exact-field filter with newest-first ordering instead of relevance ranking, use
`list` with `--from` / `--to` / `--subject` (substring, repeatable, all must match). Those
filtered `list` calls are served by search internally, so they inherit the 100 cap too.

Spam, trash, blocked, and unauthenticated items are always excluded from search — there is
no `--include-*` escape hatch on the search path, so fall back to `list` for those.

## 6. Scheduled send and conditional follow-up

```bash
# Schedule for a specific time. Auto-labeled `scheduled`.
agentmail inboxes:drafts create \
  --inbox-id "$INBOX" \
  --to prospect@example.com \
  --subject "Following up" \
  --text "Just bumping this." \
  --send-at 2026-08-18T09:00:00Z \
  --format json

# See what's queued.
agentmail inboxes:drafts list --inbox-id "$INBOX" --label scheduled --format json

# Reschedule, unschedule (keeps the draft), or cancel entirely.
agentmail inboxes:drafts update --inbox-id "$INBOX" --draft-id "$DRAFT" --send-at 2026-08-20T14:00:00Z
agentmail inboxes:drafts update --inbox-id "$INBOX" --draft-id "$DRAFT" --send-at null
agentmail inboxes:drafts delete --inbox-id "$INBOX" --draft-id "$DRAFT"
```

`send_status` is `scheduled` | `sending` | `failed`. A draft already in `sending` cannot be
edited — that returns `409`. A `failed` send can be retried by setting a new `--send-at`.

The "follow up in 3 days unless they reply" pattern is: schedule the follow-up draft, tag
the thread with `follow-up:<draft_id>`, and delete the draft when a reply arrives. Without
webhooks that means checking the thread on your own schedule.

## 7. A send went ambiguous — did it actually go out?

**Do not re-run the send.** There is no `--idempotency-key` flag, so a retry can deliver a
second real email.

```bash
# Did it land? Newest first, so a successful send shows up at the top.
agentmail inboxes:messages list --inbox-id "$INBOX" --limit 5 --format json > /tmp/am-check.json
jq -r '.messages[] | "\(.created_at)\t\(.subject)\t\(.to // [] | join(","))"' /tmp/am-check.json
```

Match on subject + recipient + timestamp. Then tell the user what you found and let them
decide whether to send again. If guaranteed-once delivery matters for a workflow, that
workflow needs `curl` with an `Idempotency-Key` header or one of the SDKs — not this CLI.

## 8. A fresh inbox per task

Inboxes are cheap and horizontal scale is the point — AgentMail's own deliverability
guidance prefers 10 sends across 100 inboxes over 1000 sends from one.

```bash
agentmail inboxes create \
  --username "task-4821" \
  --client-id "inbox-for-task-4821" \
  --display-name "Task 4821 Agent" \
  --metadata task_id=4821 \
  --metadata tenant=acme \
  --format json
```

`--client-id` makes this idempotent: the same `client_id` returns the original inbox
instead of creating a second one. Make it deterministic from your own data
(`inbox-for-task-<id>`) and never reuse one across resource types. It cannot contain `@`.

A username already in use returns `resource_taken` — pick another. Metadata merges on
update; send a key as `null` to drop it.
