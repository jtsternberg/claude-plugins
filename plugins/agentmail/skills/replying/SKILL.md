---
name: replying
description: "Answer AgentMail messages in thread — reply to the sender, reply-all to everyone on the thread, or forward to someone new, with a reviewable draft for anything consequential. Counts recipients before a reply-all and never retries a failed send. Triggers on: reply to that email, answer this message, reply all, forward this, draft a response, respond in the thread, send a reply."
when_to_use: "Use when a message needs an answer and you know what the answer is — after check-mail has read it, or when the user dictates a response. Covers reply, reply-all, forward, and the draft-then-send review path. Handing structured work to another agent has its own protocol in relay-work-order; finding and reading mail is check-mail."
argument-hint: "[the message to answer, and what to say]"
allowed-tools:
  - "Bash(bash */scripts/agentmail-preflight.sh*)"
  - "Bash(bash */scripts/agentmail-contacts.sh get*)"
  - "Bash(agentmail inboxes list*)"
  - "Bash(agentmail inboxes:messages list*)"
  - "Bash(agentmail inboxes:messages get*)"
  - "Bash(agentmail inboxes:threads get*)"
  - "Bash(agentmail inboxes:drafts list*)"
  - "Bash(agentmail inboxes:drafts get*)"
  - "Bash(jq *)"
  - "Read"
---

# Replying

Answering mail is the one place in this plugin where being slow is correct. Email cannot be
recalled and this CLI has no send idempotency, so there is no undo and no safe retry.

## Read the reference before you send

Every mechanic — verb choice, the reply-all headcount, drafts, threading, body flags,
what to do when a send fails — lives in one file, because `relay-work-order` and
`check-mail` need the same rules and a second copy would drift from this one.

Codex: substitute the installed plugin directory for the path below.

```markdown
${CLAUDE_PLUGIN_ROOT}/references/replying.md
```

**Read it before your first send in a session.** What follows here is only the part you must
not get wrong even if you read nothing else.

## The four rules

**1. Show, then send.** Put the exact `to`/`cc`/`bcc`, the subject, and the full body in
front of the user and get explicit confirmation. One confirmation covers one send, not a
session. Sends are deliberately absent from `allowed-tools` so the harness prompts too —
that prompt is the feature, and broadening to `Bash(agentmail *)` would remove the only
harness-level guard on an irreversible action.

**2. Count before `reply-all`.** `inboxes:messages reply-all` takes no `--to/--cc/--bcc` —
the API forbids explicit recipients there — so the blast radius is whatever is already on
the thread and you cannot trim it at send time. Read the thread, tell the user the number,
then send. Cap is 50 across `to`+`cc`+`bcc`.

**3. Draft anything the user did not dictate.** A draft is a reviewable artifact instead of
a claim about what you were about to write, `--client-id` makes creating it idempotent, and
it is AgentMail's own human-in-the-loop recommendation. Show `drafts get` output, then
`drafts send` after approval.

**4. Never retry a failed send.** Timeout, 5xx, killed process, unclear error — do not
re-run it. Check whether it landed:

```bash
agentmail inboxes:messages list --inbox-id <id> --limit 5 --format json > /tmp/am-check.json
```

Then decide with the user. A retry can deliver a second real email.

## Reply in the thread, not to the subject

Use `inboxes:messages reply` against the message you are answering, so `In-Reply-To` and
`References` are set for you. A fresh `send` with `Re:` typed into the subject starts a
thread the other side cannot correlate — and on AgentMail it also changes which allow/block
lists apply, since inbound replies are matched on `In-Reply-To` and evaluated against the
*reply* lists rather than the receive lists.

## Quote the new content, not the whole chain

Read the message you are answering in full first — `preview` is a truncated excerpt and is
not the message. Use `extracted_text`, which carries the new content with the quoted history
stripped; raw `text`/`html` include the entire chain.

## Check the recipient exists before trusting it

If the address came from memory rather than from the message in front of you, look it up:

```bash
# Codex: substitute the installed plugin directory for this path.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/agentmail-contacts.sh" get "<name>"
```

Repeat that assignment in every block — Codex shells keep no state between blocks. Exit `3`
means no such contact, which is worth saying out loud before you send rather than after.

Replying to a message in the inbox needs no lookup: the address is on the message. This
matters for `forward` and for a new `send`, where the recipient comes from you.

## When the send is refused

`403 message_rejected` usually means the org is not OTP-verified, which restricts sends to
the human's own signup address. Branch on the error `code`, never on `name` or `message` — a
permission denial still reads `Forbidden` — and read the `fix` field back to the user, since
it is usually the answer. Full error table in `using-agentmail`.

## Not this skill

Structured agent-to-agent work orders have their own subject tags, body template, and
guardrails: use `relay-work-order`. Finding and triaging mail is `check-mail`. Setup, keys,
and the rest of the command surface are in `using-agentmail`.
