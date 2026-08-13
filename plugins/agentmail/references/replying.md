# Replying, forwarding, and the draft-first path

The mechanics of answering mail. Read by `replying`, `relay-work-order`, and `check-mail`,
which is why this lives at the plugin root instead of inside one of them.

Flags come from `--help`, always. This file is the part `--help` cannot tell you: most
command descriptions in the shipped binary are the literal string `**CLI:**`.

## The gate comes first

**Show the user the exact recipients (`to`/`cc`/`bcc`), the subject, and the body, and get
explicit confirmation, before running anything that sends** — `send`, `reply`, `reply-all`,
`forward`, `drafts send`. One confirmation covers one send, not a session.

Email cannot be recalled, and this CLI exposes no send idempotency (`--client-id` covers
resource *creation*; sends need an `Idempotency-Key` HTTP header and there is no flag for
it). So there is no safe retry to fall back on, which is why the gate is worth the latency.

`allowed-tools` in every skill here grants reads only. Sends fall through to a permission
prompt on purpose. Do not "fix" that by broadening to `Bash(agentmail *)`;
`tests/safety_test.sh` fails if a send or delete verb appears in an allowlist.

## Choosing the verb

| Situation | Command |
|---|---|
| Answering the sender only | `inboxes:messages reply` |
| Answering everyone on the thread | `inboxes:messages reply-all` |
| Passing a message to someone new | `inboxes:messages forward` |
| Anything the user did not dictate | `inboxes:drafts create` → show → `drafts send` |

**Prefer the explicit `reply-all` command over `reply --reply-all`.** Both exist. The
separate command makes the blast radius legible in the transcript and in the permission
prompt the user sees — which is the only place they get to catch it.

**`reply-all` needs a headcount before it runs.** It accepts no `--to/--cc/--bcc` (the API
forbids explicit recipients when replying to all), so the recipients are whatever is
already on the thread and you cannot trim them at send time. Read the thread, tell the
user how many addresses will receive it, then send. The cap is 50 across `to`+`cc`+`bcc`.

**Forwarding carries the whole quoted history.** Check what is in the body before forwarding
a thread to a new recipient — a forward is the easiest way to disclose something the
original sender said in a narrower context.

## The draft-first path

For anything the user has not dictated verbatim:

```bash
agentmail inboxes:drafts create --inbox-id <id> --client-id <stable-id> --in-reply-to <message-id> --text ...
agentmail inboxes:drafts get --inbox-id <id> --draft-id <did> --format json   # show the user
agentmail inboxes:drafts send --inbox-id <id> --draft-id <did>                # after they approve
```

`--client-id` makes the *create* half idempotent, and the draft is a reviewable artifact
rather than a claim about what you were about to send. This is also AgentMail's own
human-in-the-loop recommendation.

Two things about drafts that are easy to get wrong:

- **A draft's kind is fixed at creation.** `--in-reply-to` and `--forward-of` are mutually
  exclusive, and a plain draft cannot be converted into a reply. Create a new one.
- **`--send-at <ISO8601>` schedules it** and auto-applies the `scheduled` label.
  `--send-at null` unschedules but keeps the draft. A draft already in `sending` state
  returns `409` on edit.

## Staying in the thread

Reply *to a message*, not to a subject line. `inboxes:messages reply` sets `In-Reply-To`
and `References` for you; a fresh `send` with `Re:` typed into the subject starts a new
thread that the other side cannot correlate — and on AgentMail it also changes which
lists apply, because inbound replies are matched on `In-Reply-To` and evaluated against
the *reply* allow/block lists rather than the receive lists.

## Writing the body

- **`--text "$(cat body.txt)"` carries a long body** (and `--html "$(cat body.html)"`).
  Command substitution in double quotes is not re-expanded, so it delivers arbitrary prose
  verbatim. Short bodies can be inline literals.
- **Do not use `@file://` argument-loading for the body.** It is documented but broken on
  0.7.14 — `--text "@file:///path"` sends the literal path string, not the file, with exit
  0 and no warning (verified on `reply`, `send`, and `drafts create`).
- **Verify after sending.** A successful send is not proof the body is intact: `get` the
  sent message and compare its `text` length against your source before trusting it.
- **Send both `text` and `html`** whenever you send HTML at all. The plain-text part is the
  fallback for clients that will not render HTML, and it measurably helps deliverability.
- **Email addresses are safe unquoted** (`--to user@example.com`) — the `@` is mid-string,
  not leading.

## When a send fails

**Never retry it.** On any ambiguous failure — timeout, 5xx, killed process, unclear error
— do not re-run the command. Check whether it actually went out:

```bash
agentmail inboxes:messages list --inbox-id <id> --limit 5 --format json > /tmp/am-check.json
```

Then decide with the user. A retried send can deliver a second real email, because there is
no idempotency key available from the CLI.

`403 message_rejected` is the one failure with a specific, common cause: an unverified org
restricts sends to the human's own signup address, so a send to anyone else fails until OTP
verification completes. Branch on the error `code`, not on `name` or `message` — a
permission denial still reads `Forbidden` and tells you nothing — and read the `fix` field
back to the user, since it usually is the answer.
