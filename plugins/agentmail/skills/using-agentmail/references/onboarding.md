# Onboarding: agent self-signup, OTP, and key storage

Read this before running signup. The flow has one human-in-the-loop step that cannot be
automated, and one credential-handling rule that matters more than the commands.

## Which path?

| Situation | Path |
|---|---|
| No AgentMail account at all, agent signs itself up | **Agent self-signup** (below) |
| A human already has an account, or the OTP email never arrives | **Console key**: create one at [console.agentmail.to/dashboard/api-keys](https://console.agentmail.to/dashboard/api-keys) using the same human email (pick a scope + access — see [Console key: scope and access](#console-key-scope-and-access) below), then `export AGENTMAIL_API_KEY=...` |
| A working key already exists | Nothing to do. Do **not** sign up again — it rotates the key. |

Self-signup is for **first-time users only**. A human email address already signed up with
AgentMail will not work through this flow.

**Rule out an existing key before you sign up.** A preflight `exit 11` means no key *in
this shell* — not that none exists. Because signup **rotates** any existing key, creating
one when the user already has a working key elsewhere silently invalidates it. So when the
key is merely unset in the environment, check the likely stashes first: a prior credential
file at `~/.config/agentmail/signup-*.json`, the user's shell profile or secret manager, or
an `AGENTMAIL_API_KEY` line in their dotfiles. Found one → export and use it; don't sign
up. Only take the signup path when there is genuinely no key anywhere.

## Console key: scope and access

Creating a key at
[console.agentmail.to/dashboard/api-keys](https://console.agentmail.to/dashboard/api-keys)
forces two required choices. Pick them for what this skill does, not by reflex.

**SCOPE — where the key may act:**

- **Entire organization** — every inbox and domain the org owns. **Choose this** for the
  skill's full surface: it lists inboxes and can *create* them, both of which need org-wide
  reach.
- **Single inbox** — one inbox only; the least-privilege choice, correct when the agent
  should live in exactly one inbox and never create others. `inboxes create` and org-wide
  `inboxes list` will `403` under this scope.
- **Single pod** — one tenant's inboxes/domains. Only relevant if you use pods (out of
  scope for v0.1).

**ACCESS — what it may do there:**

- **Send & read mail** — read inboxes/threads, read and send messages and drafts. The core
  the skill needs.
- **Manage inboxes** — create/update/delete inboxes. Add this **on top of** Send & read
  mail if the agent should create inboxes (`inboxes create`). The self-signup key already
  has it; a console key does not unless you check it.
- **Full access within scope** — everything in the catalog for that scope; same as leaving
  access unset. Simplest if you don't want to reason about it.
- **Read-only** — **do not pick this for this skill.** Every send, reply, and draft-send
  will `403`. A read-only key is *not* how you make sending safe — that is the skill's
  permission gate (below), which prompts on every send regardless of what the key can do.
- **Advanced / Custom** — hand-pick permissions; only if you already know the catalog.

**Recommended default:** SCOPE *Entire organization* + ACCESS *Send & read mail* and
*Manage inboxes* (or *Full access within scope*). That matches what the self-signup key can
do, so the whole skill works. **Narrowest that still functions:** SCOPE *Single inbox* +
ACCESS *Send & read mail* — send/read/reply/draft on one existing inbox, no creation.

The key's ACCESS is a **server-side** limit, independent of the skill's own send gate:
sends stay off `allowed-tools`, so Claude Code prompts on each one no matter how broad the
key is. Both layers apply.

## The rule that shapes everything else

`agentmail agent sign-up` returns `{api_key, inbox_id, organization_id}` **on stdout**.

Run bare by an agent, that writes a live API credential into the conversation transcript.
Transcripts are archived, and in this environment they are also auto-ingested into a local
searchable index — so "it was only in my terminal" is not true. A key in a transcript is a
key in a database.

So: **never run `agentmail agent sign-up` directly.** Use the script. It captures the
response, writes it to a `0600` file outside any repository, and prints only masked values
plus the path.

## Step 1 — sign up

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/agentmail-signup.sh" \
  --human-email you@example.com \
  --username my-agent
```

**Settle both inputs with the user before running it — both are required, and the second
is user-facing:**

- `--human-email` — where the 6-digit OTP goes, and (until verification) the only address
  the agent can email. Ask which address; don't assume.
- `--username` — becomes the agent's actual address, `<username>@agentmail.to` — what
  recipients see and reply to. **Let the user choose it; don't pick one silently.** Must be
  alphanumeric with `. _ -` and cannot lead with a separator. The script requires it
  (omitting it exits `64`), so gather it up front rather than discovering the requirement
  mid-flow.

The key this returns is **organization-scoped** with send/read *and* inbox management — it
can create inboxes and send, matching the skill's full surface. That is why self-signup
users never pick a scope: they get the broad key automatically. Only the console-key path
(above) makes you choose.

Output is masked: `inbox_id`, `organization_id`, a key fingerprint like `am_us_…a1b2`, and
the path to the credential file. Exit codes: `0` signed up · `40` refused because
`AGENTMAIL_API_KEY` is already set · `64` bad arguments · `1` the call failed.

### The rotation guard

The script refuses to run when `AGENTMAIL_API_KEY` is already set, unless you pass
`--force`. Sign-up is idempotent in the sense that it will not create a second
organization — but for an email that already signed up it **rotates the API key**, which
silently invalidates the key in the current environment. Nothing at the call site warns
you; you find out later when unrelated commands start returning 401.

If a working key already exists, you do not need signup at all.

## Step 2 — the human reads the OTP

A 6-digit code goes to `--human-email`. This step needs a person. Ask the user for the
code; do not try to fetch it.

Constraints worth stating to the user up front:

- **Expires 24 hours** after issue.
- **Maximum 10 attempts.**
- **Attempt exhaustion is worse than it sounds:** while the exhausted code is still live,
  every submission is rejected — *including the correct one* — until it expires. Only then
  does `agent sign-up` issue a fresh code with a reset attempt count. If the code has
  already expired, sign up again immediately.
- **If the email never arrives**, skip the OTP entirely: the human can create an account
  at [console.agentmail.to/dashboard/api-keys](https://console.agentmail.to/dashboard/api-keys)
  with the same human email and generate a key from the dashboard (pick a scope + access —
  see [Console key: scope and access](#console-key-scope-and-access) below).

## Step 3 — verify

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/agentmail-verify.sh" --otp-code 123456
```

The script sources the key from the newest `signup-*.json` (or `--key-file`, or an already
exported `AGENTMAIL_API_KEY`), exports it only inside its own process, and verifies. It
validates the code is exactly six digits **before** calling out, because attempts are
finite and a typo should not cost one.

Exit codes: `0` verified · `41` no key found anywhere · `64` malformed OTP (nothing sent,
no attempt spent) · `1` verification failed.

On success it records `{"verified": true, "verified_at": ...}` to
`${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/state.json`.

## Step 4 — the user stores the key

**This is the user's action, not the agent's.** The full key is in the credential file. Do
not `Read` that file into the conversation — that would undo the whole point of step 1.

Point the user at the path and let them copy it into wherever they keep secrets: shell
profile, password manager, a secrets store. Then:

```bash
export AGENTMAIL_API_KEY=...    # value from the credential file
```

Once it is stored durably the credential file can be deleted. Never commit it. Never write
it into a project `.env`.

## Why the preflight says "verification: unknown"

Because it cannot know, and guessing would be worse.

The `agent_unverified → agent_verified` transition is real — verifying lifts the send
allowlist. But **no documented AgentMail GET exposes it.** `organizations get` returns
counts, limits, billing metadata, and `authentication_*` fields; `GET /v0/auth/me` returns
scope information. Neither carries a verification flag, and the CLI does not surface an
`auth` resource at all (there is no `agentmail auth` command in v0.7.14).

So there are exactly two signals:

1. **Local and positive:** `state.json` says `verified: true` because *this machine* ran a
   successful verify. The preflight surfaces it as a hint.
2. **Remote and negative:** a send to a non-signup address returns
   `403 message_rejected`. That is the definitive "still unverified" answer, and you only
   get it by trying.

Absence of signal 1 means **unknown**, never "unverified" — the user may have verified on
another machine, or be using a console key that was never in this flow at all.

## First-send checklist after onboarding

1. `agentmail inboxes list --format json` — confirm the auto-created inbox exists.
2. Send **to the human's own signup address**. On an unverified org it is the only thing
   that works, which makes it the correct smoke test.
3. Then `agentmail inboxes:messages list --inbox-id <id> --limit 5 --format json` and
   confirm the send is recorded.
4. Only after that, try a third-party recipient. A `403 message_rejected` here means
   verification is still outstanding — go back to step 2 of this document.
