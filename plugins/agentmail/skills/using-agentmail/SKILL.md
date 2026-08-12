---
name: using-agentmail
description: "Sends and receives email for an AI agent via the AgentMail API and the `agentmail` CLI — create inboxes, send mail, read incoming messages and threads, reply / reply-all / forward, manage drafts, and run the agent self-signup + OTP verification flow."
when_to_use: "Use when the user wants an agent to have its own email address or to act on email: sign up for AgentMail, create or list inboxes, send an email, check for new mail, read a message or thread, reply or forward, prepare or send a draft, or schedule a send. Also use when AgentMail setup is failing — a missing CLI, a missing or rejected AGENTMAIL_API_KEY (a bad key returns a bare 403 with no error code), or a 403 message_rejected on a send, which means the org still needs OTP verification or the recipient is off the send allowlist."
argument-hint: "[what you want to do with email]"
allowed-tools:
  - "Bash(command -v agentmail)"
  - "Bash(agentmail --version)"
  - "Bash(agentmail --help)"
  - "Bash(agentmail organizations get*)"
  - "Bash(agentmail inboxes list*)"
  - "Bash(agentmail inboxes get*)"
  - "Bash(agentmail inboxes:messages list*)"
  - "Bash(agentmail inboxes:messages get*)"
  - "Bash(agentmail inboxes:messages get-raw*)"
  - "Bash(agentmail inboxes:messages search*)"
  - "Bash(agentmail inboxes:threads list*)"
  - "Bash(agentmail inboxes:threads get*)"
  - "Bash(agentmail inboxes:threads search*)"
  - "Bash(agentmail inboxes:drafts list*)"
  - "Bash(agentmail inboxes:drafts get*)"
  - "Bash(agentmail threads list*)"
  - "Bash(agentmail threads get*)"
  - "Bash(agentmail threads search*)"
  - "Bash(agentmail drafts list*)"
  - "Bash(agentmail drafts get*)"
  - "Bash(bash */scripts/agentmail-preflight.sh*)"
  - "Bash(jq *)"
  - "Read"
---

# AgentMail

Give an agent its own email address and run a full round trip on it: create inboxes,
send, read what comes back, reply / reply-all / forward, and stage drafts for review.
Driven entirely by the official `agentmail` CLI.

This is **AgentMail specifically** — an email API built for agents, where every inbox is
an API resource. It is not the user's own mail: reading or sending the user's Gmail is the
`gws` plugin. It is not raw SMTP.

## This is the hub. Four sibling skills go deeper

Use them instead of this file when the task is one of theirs; come back here for setup,
flags, errors, and anything the others do not cover.

| Skill | For |
|---|---|
| `contacts` | the address book — who is who, and which address is actually verified |
| `check-mail` | what arrived, reading full bodies, and triaging an inbox |
| `replying` | reply / reply-all / forward, draft-first for anything consequential |
| `relay-work-order` | handing work to (or taking work from) another agent over email |

Two shared references sit at the plugin root because more than one skill needs each:
`references/replying.md` (the mechanics of answering mail) and
`references/agent-mail-protocol.md` (the `[HANDOFF]`/`[ASK]`/`[FYI]`/`[DONE]` contract).

Codex: substitute the installed plugin directory for the path below.

```markdown
${CLAUDE_PLUGIN_ROOT}/references/replying.md
${CLAUDE_PLUGIN_ROOT}/references/agent-mail-protocol.md
```

## The golden rule, split in two

`agentmail` ships often and its flags move. **Never construct a real invocation from
memory or from this file — run `agentmail <resource> <cmd> --help` first.** That is the
only trustworthy source for flags.

But `--help` alone is not enough here, and the reason is specific. Most command
descriptions in the shipped binary are the literal string `**CLI:**` — a docs-generation
artifact:

```
agentmail inboxes create - **CLI:**
agentmail inboxes:messages send - **CLI:**
```

Flags are intact; the prose is gone. So the split is:

- **Flags → `--help`.** Always. Do not trust flag lists written down anywhere, including here.
- **Meaning → this file.** What a command actually does, what is irreversible, which
  arguments conflict, what the blast radius is. The CLI no longer tells you, so the
  semantic notes below are load-bearing rather than decorative.

Also: `agentmail help <cmd>` does not exist. Only `<cmd> --help`.

## Current environment (resolved at skill load)

Codex: this path resolves under Claude Code; substitute the installed plugin directory.

```!
# Codex: this path resolves under Claude Code; substitute the installed plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/agentmail-preflight.sh" --local
```

The preflight lives at the **plugin root**, not in this skill's directory: four skills and
the mail-check hook all run it, and one copy is the repo's rule for that
(AGENTS.md § Sharing Code or Docs Between Sibling Skills). `agentmail-signup.sh` and
`agentmail-verify.sh` have one consumer each and stay under this skill's `scripts/`.

Codex does not execute `!` blocks, so under Codex the above has not run: **run the
preflight script yourself as your first step**, substituting this skill's directory for
the path.

`--local` is deliberately offline — CLI presence, version, and whether a key is set. No
API call at load time: a round trip on every load costs latency and quota and would print
org and inbox identifiers into context for tasks that never touch email. When you actually
need to know the key works, run the same script with no flag (one `inboxes list`, which
also prints the inbox id you will need next).

Exit codes, so you can branch without reading prose: `0` key accepted (**including a
recognized key that is merely scope-limited**) · `10` no CLI · `11` no key · `12` key
rejected — malformed, revoked, or rotated · `20` local-only OK · `30` probe inconclusive
(network/429/5xx — **not** a bad key).

**`organizations get` is not the auth probe, and must not be used as one.** It has no
required flags, which made it look like the cheapest check, but it succeeds *only* on an
organization-scoped key. Verified live: an inbox-scoped key gets
`403 missing_permission` from it — a working key, refused. `inboxes list` succeeds on
inbox-, pod-, and org-scoped keys alike. And by the same logic, a `missing_permission`
refusal anywhere is a **scope** answer, never a credential answer: the key was recognized
well enough to be told which permission it lacks.

## Setup

**CLI missing (exit 10):** offer the options and stop. **Never run an installer without
explicit user consent** — global npm state is machine-wide and not something the user can
un-notice.

```
npm install -g agentmail-cli     # official. The npm package is a thin wrapper whose
                                 # postinstall downloads a Go binary from GitHub
                                 # releases, so this needs network + github.com
npx agentmail-cli <args>         # no global install; pays the download on a cold cache
```

**No key (exit 11):** exit 11 means no key *in this shell* — not that none exists. Before
signing up, rule out a key that's merely unexported: signup **rotates** any existing key,
so creating one when the user already has a working key (in their shell profile, a secret
manager, a prior `~/.config/agentmail/signup-*.json`, or an `AGENTMAIL_API_KEY` in their
dotfiles) silently breaks the old one. If there's genuinely no key anywhere, then either
agent self-signup (below) or a human creates one at
[console.agentmail.to/dashboard/api-keys](https://console.agentmail.to/dashboard/api-keys)
(that page requires picking a **scope** and an **access** level — see
[references/onboarding.md](references/onboarding.md) for which to choose). Read
onboarding.md before starting signup.

**Key rejected (exit 12):** it was revoked, malformed, or **rotated** — re-running
`agent sign-up` for an email that already signed up rotates the key and silently
invalidates the old one.

## Onboarding: signup → OTP → verify

Full walkthrough in [references/onboarding.md](references/onboarding.md). The shape:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/agentmail-signup.sh" --human-email you@example.com --username my-agent
# → a human reads the 6-digit code from their email
bash "$SKILL_DIR/scripts/agentmail-verify.sh" --otp-code 123456
```

Both `--human-email` and `--username` are **required**, and `--username` becomes the
agent's real address (`<username>@agentmail.to`) — the thing recipients see and reply to.
Ask the user for both up front and let them choose the username; don't pick one silently or
discover the requirement mid-flow. (The console-key alternative instead makes you choose a
**scope** and **access** level — which to pick is in
[references/onboarding.md](references/onboarding.md).)

Three things that matter more than the commands:

**Never run `agentmail agent sign-up` directly.** It returns the API key on stdout, which
puts a live credential into this transcript — and transcripts get archived and indexed.
The script captures it to a `0600` file outside any repo and prints only a masked
fingerprint plus the path. Do not `Read` that file into the conversation; point the user
at it so *they* can store the key.

**The OTP step requires a human** and cannot be automated away. The code goes to the
human's email, expires in 24h, and allows 10 attempts — after which even the correct code
is rejected until it expires.

**Until verification succeeds, the only address the agent can email is the human's own
signup address.** Anything else fails `403 message_rejected`. And there is no way to check
verification state up front: the API exposes no verification field on any documented GET,
so `403 message_rejected` on a send to a third party *is* the signal. The preflight will
say "verification: unknown" and that is honest, not a bug.

## Before you send: the gate

**Show the user the exact recipients (`to`/`cc`/`bcc`), the subject, and the body, and get
explicit confirmation, before running any command that sends mail** — `send`, `reply`,
`reply-all`, `forward`, `drafts send`. One confirmation covers one send, not a session.

Email cannot be recalled, and — see below — there is no CLI-level idempotency that would
make a retry safe. This is the one place in this skill where being slow is correct.

Three rules that follow from it:

**Prefer the draft-first path** for anything the user has not dictated verbatim:

```bash
agentmail inboxes:drafts create --inbox-id <id> --client-id <stable-id> --to ... --subject ... --text ...
agentmail inboxes:drafts get --inbox-id <id> --draft-id <did> --format json   # show the user
agentmail inboxes:drafts send --inbox-id <id> --draft-id <did>                # after they approve
```

`--client-id` makes the *create* half idempotent, and the draft is a reviewable artifact
rather than a claim about what you were about to do. This is also AgentMail's own
human-in-the-loop recommendation.

**`reply-all` needs a headcount first.** `inboxes:messages reply-all` accepts no
`--to/--cc/--bcc` — the API forbids explicit recipients when replying to all — so the
blast radius is whatever is already on the thread. Read the thread, tell the user how many
addresses will receive it, then send. The cap is 50 recipients across `to`+`cc`+`bcc`.

**The safe rehearsal is emailing the human's own signup address.** On an unverified org
it is the only thing that works, which makes it the right first test after setup.

### Why sends are not on the allowlist

`allowed-tools` covers the read/list/get/search surface and nothing that sends, creates,
updates, or deletes. That is deliberate: every mutating command falls through to a Claude
Code permission prompt, so the harness asks the user before an irreversible action even if
the model has convinced itself the intent was clear.

**Do not "fix" this by broadening to `Bash(agentmail *)`.** The prompt is the feature.
`tests/safety_test.sh` fails if a send or delete verb appears in `allowed-tools`.

## Idempotency: `client_id` does not cover sends

Two different mechanisms, and only one is reachable from the CLI:

| | Mechanism | CLI |
|---|---|---|
| Creating resources (inboxes, drafts) | body `client_id` | `--client-id` ✅ |
| **Sends** (send, reply, forward, drafts send) | **`Idempotency-Key` HTTP header** | **no flag** ❌ |

`--headers` is *email* headers placed into the message, not HTTP request headers. There is
no `--idempotency-key`, no `--max-retries`, no `--timeout`.

So the rule is the opposite of a retry loop:

> **Never retry a failed send.** On any ambiguous failure — timeout, 5xx, killed process,
> unclear error — do not re-run the command. Check whether it actually went out:
>
> ```bash
> agentmail inboxes:messages list --inbox-id <id> --limit 5 --format json
> ```
>
> Then decide with the user. If a guaranteed-once send genuinely matters, drop to `curl`
> with an `Idempotency-Key` header, or use the Python/TypeScript SDK, which can set it.

## Command surface, by task

Flags from `--help`. This table is for *finding* the command, not for calling it.

| Task | Command |
|---|---|
| Am I authenticated? | `inboxes list` — works on any key scope, and returns the inbox id |
| Sign up an agent | `agent sign-up` — **via the script**, never directly |
| Verify OTP | `agent verify` — via the script |
| Create / list / get an inbox | `inboxes create` · `inboxes list` · `inboxes get` |
| Send new mail | `inboxes:messages send` |
| Read an inbox | `inboxes:messages list` |
| Read one message | `inboxes:messages get` · `get-raw` (presigned `.eml` URL) |
| Full-text search | `inboxes:messages search` · `inboxes:threads search` · `threads search` |
| Reply | `inboxes:messages reply` · `inboxes:messages reply-all` |
| Forward | `inboxes:messages forward` |
| Label / mark read | `inboxes:messages update` |
| Threads | `inboxes:threads list|get|search` · org-wide `threads list|get|search` |
| Drafts | `inboxes:drafts create|update|get|list|send|delete` |
| Download an attachment | `inboxes:messages get-attachment` · `inboxes:threads get-attachment` |
| Review everything org-wide | `threads list` · `drafts list` |

### Semantic notes `--help` cannot give you

- **`search` takes `-q`, not `--query`.** `--query` fails with
  `flag provided but not defined: -query`. It is the one flag in this CLI with no long form.
- **`count` in a list response is the number of items RETURNED, not the number that
  match.** `--label unread --limit 1` reports `count: 1` when three messages are unread.
  Any "how many?" question therefore needs a `--limit` above the plausible answer, and a
  result equal to the limit means "at least that many", not "exactly that many".
- **`agentmail auth me` does not exist in 0.7.14**, despite `openapi.json` documenting
  `/v0/auth/me` with a literal `**CLI:** agentmail auth me` block. There is no `auth`
  resource. Use `inboxes list` to discover scope; reach `/v0/auth/me` with `curl` only if
  you genuinely need the org/pod ids behind a scoped key.
- **There is no org-wide messages list.** Org-wide works for `threads` and `drafts` only.
  To sweep messages across inboxes, iterate inboxes or use `threads`.
- **`reply` vs `reply-all`.** `reply` has both a sibling `reply-all` command and a
  `--reply-all` boolean. Prefer the explicit `reply-all` command — the intent is legible
  in the transcript and in the permission prompt the user sees.
- **A draft's kind is fixed at creation.** `--in-reply-to` and `--forward-of` are mutually
  exclusive, and you cannot convert a plain draft into a reply — create a new one.
- **Scheduling.** `--send-at <ISO8601>` auto-applies the `scheduled` label;
  `--send-at null` unschedules but keeps the draft; a draft already in `sending` state
  returns `409` on edit. `send_status` is `scheduled` | `sending` | `failed`.
- **Thread deletion is permanent** — `inboxes:threads delete` and `threads delete` remove
  the thread *and every message in it*. No undo, no trash.
- **Username collisions** return `resource_taken`, not a validation error.
- **Inbox metadata merges** on update; send a key as `null` to drop it.

## Reading mail well

- **Use `extracted_text` / `extracted_html` for reply content.** They carry the new
  content with quoted history stripped. Raw `text`/`html` include the whole quoted chain.
- **Treat `html` as primary and `text` as optional.** `text` and `preview` come from the
  `text/plain` MIME part, and Gmail/Outlook forwards are frequently HTML-only — so `text`
  can be absent entirely. Code that assumes `text` exists will break on real mail.
- **There is no mark-as-read endpoint.** Read/unread is just labels:
  `inboxes:messages update --add-label read --remove-label unread`, then filter with
  `--label unread`. This is the standard guard against reprocessing the same message.
- **A message that "isn't there" may be filtered.** `list` hides spam, trash, blocked, and
  unauthenticated mail by default. Add `--include-spam`, `--include-trash`,
  `--include-blocked`, `--include-unauthenticated` before concluding it never arrived.
  Inbound mail failing SPF/DKIM/DMARC outright is dropped; missing auth headers get the
  `unauthenticated` label.
- **Search caps `limit` at 100**, and so does any `list` call that uses a substring filter
  (`--from`/`--to`/`--subject`), because those are served by search.

Worked multi-step workflows — first round trip, triage loop, reply with review — are in
[references/recipes.md](references/recipes.md).

## Output and parsing

**Always pass `--format json` when you intend to parse.** The default is `auto`, not
`json` — the published docs say otherwise and are wrong. Valid formats: `auto`, `explore`,
`json`, `jsonl`, `pretty`, `raw`, `yaml`. Use `pretty` when the output is for the user to
read, not for you to parse.

**Save output to a file, then parse the file.** Do not pipe `agentmail` straight into
`jq`: when the parse fails you are left guessing at output you never saw.

```bash
agentmail inboxes:messages list --inbox-id "$INBOX" --limit 10 --format json > /tmp/am-msgs.json
jq -r '.messages[] | "\(.message_id)\t\(.subject)"' /tmp/am-msgs.json
```

The CLI can also filter server-side without any external tool: `--transform` takes
[GJSON](https://github.com/tidwall/gjson) syntax, and `-r` prints a bare string without
JSON quotes.

## Quoting, `@`, and multi-line bodies

- **A leading `@` on an argument loads a file.** `@file://x.txt` forces string encoding,
  `@data://x.bin` forces base64, and absolute paths take a third slash
  (`@file:///tmp/x.txt`). To pass a literal leading `@`, escape it: `--username '\@abe'`.
- **Email addresses are safe unquoted** — `--to user@example.com` — because only a
  *leading* `@` triggers the file path. (Worth one probe the first time you send.)
- **For bodies, use `--text` and `--html` flags.** The CLI is documented to accept a
  JSON/YAML request body on stdin via heredoc, which would be the cleaner answer for long
  HTML, but that path is unverified here — confirm it works before relying on it.
- **Send both `text` and `html`** when you send HTML at all. The plain-text part is the
  fallback for clients that will not render HTML, and it measurably helps deliverability.

## Attachments

Downloading works today: `inboxes:messages get-attachment` /
`inboxes:threads get-attachment`.

**Sending attachments is not covered by this skill version.** The docs show dotted flags
(`--attachment.content`, `--attachment.filename`) that the installed `--help` does not
list — it shows only `--attachment value`. One of the two is wrong. Run
`agentmail inboxes:messages send --help`, and probe on a **draft** (which you can inspect
and delete) before attaching anything to a real send.

## Errors

**Branch on `code`, never on `name` or `message`.** AgentMail keeps the legacy
`name`/`message` values for backward compatibility, so a permission denial still reads
`Forbidden` and tells you nothing. `code` identifies the cause, `fix` states the remedy,
and `docs` links the reference. **Read `fix` back to the user** — it is usually the answer.

**But `code` is not always there — fall back to the HTTP status.** The docs state that
every error response carries a `code`; that is not true in practice. Verified live against
`api.agentmail.to`, an invalid API key returns:

```
GET "https://api.agentmail.to/v0/organizations": 403 Forbidden
{ "message": "Forbidden" }
```

No `code`, no `fix`, and **403 rather than the documented 401**. So when `code` is absent,
classify from the status line the CLI prints to stderr: `401`/`403` is a credential
problem (rejected key, or a scope/permission gap), `429` is rate limiting, `5xx` is
transient. Do not read a missing `code` as "unknown failure" and go looking for a network
problem.

| `code` | What it usually really means |
|---|---|
| `message_rejected` | Unverified org (sends restricted to the signup address), a send block/allow list, a suspended account, or an unfetchable attachment URL |
| `not_found` | Possibly a wrong ID — but also how the API hides resources outside your key's scope, or behind a restricted-label read permission (`spam`, `blocked`, `trash`, `unauthenticated`). A correct ID can return this. |
| `unknown_api_key` / `unauthorized` | Key revoked, malformed, or rotated by a repeat `agent sign-up` |
| `missing_permission` | Restricted key; the missing permission is named in `fix`. A key cannot grant itself a permission it lacks. |
| `rate_limit_exceeded` | 429 — honor `Retry-After` |
| `limit_exceeded` | Also the OTP-attempt case: the exhausted code stays live and rejects even the correct code until it expires 24h after issue |
| `conflict` | An `Idempotency-Key` reused for a different request, or a first send still in flight |
| `resource_taken` | Inbox username already in use |
| `domain_not_verified` | Add the DNS records from `domains get`, then `domains verify` |

**On 429:** the CLI is Stainless-generated and carries retry/backoff internals, so by the
time you see a 429 it has likely already retried. Wait the advertised `Retry-After` and
retry a **read** once. Never retry a send (see above).

## Troubleshooting

- **`agentmail: command not found`** — not installed, or npm's global bin is not on PATH.
  Offer the install; do not run it.
- **The CLI tells you to reinstall `@agentmail/cli`** — that package does not exist. The
  published name is `agentmail-cli`. The wrapper's error message is wrong.
- **`npm install -g agentmail-cli` fails at postinstall** — it downloads a binary from
  GitHub releases, so a private npm mirror is not sufficient; it needs github.com.
- **Sends fail 403 but reads work** — almost always an unverified org. Verify the OTP.
- **`agentmail help <cmd>` errors** — that form does not exist; use `<cmd> --help`.
- **A message you know arrived is missing from `list`** — see the `--include-*` flags above.
- **Output looks like a table when you wanted JSON** — `--format` defaults to `auto`.

## Everything else (vocabulary only)

Named so you know it exists; get signatures from `--help` and concepts from
[docs.agentmail.to](https://docs.agentmail.to) (append `.md` to any docs URL for clean
markdown).

- **Webhooks** (`webhooks create|update|list|get|delete`) and **WebSockets** — real-time
  inbound delivery. Both need a public URL or a long-lived process, so they are outside
  what a CLI skill should set up. Route the user to the docs.
- **Pods** (`pods`, `pods:*`) — multi-tenant isolation.
- **Domains** (`domains`, `get-zone-file`, `verify`) — custom sending domains, SPF/DKIM/DMARC.
- **Lists** (`lists`, `inboxes:lists`) — send/receive allow and block lists.
- **API keys** (`api-keys`, `inboxes:api-keys`) — scoped and permissioned keys.
- **Labels** — arbitrary strings; the state machine for agent workflows.
