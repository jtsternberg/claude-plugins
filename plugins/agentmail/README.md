# agentmail

Give an agent its own email address, and run a full round trip on it: create inboxes,
send, read what comes back, reply / reply-all / forward, and stage drafts for review.

Driven by the official [`agentmail` CLI](https://docs.agentmail.to/integrations/cli)
against the [AgentMail API](https://docs.agentmail.to) — an email API where every inbox
is an API resource, built for agents rather than people.

**Install:** `claude plugin install agentmail@jtsternberg`

Ships one skill: `using-agentmail` — `/agentmail:using-agentmail` in Claude Code,
`$agentmail:using-agentmail` in Codex.

## Setup

The plugin never installs anything for you. It detects what is missing and tells you how
to fix it.

```bash
npm install -g agentmail-cli      # the npm package is a thin wrapper whose postinstall
                                  # downloads a Go binary from GitHub releases, so this
                                  # needs network access to github.com
export AGENTMAIL_API_KEY=am_...   # from signup below, or console.agentmail.to/dashboard/api-keys
```

If the CLI ever tells you to reinstall `@agentmail/cli`, ignore it — that package does
not exist. The published name is `agentmail-cli`.

### Getting a key: agent self-signup

AgentMail lets an agent register itself, no dashboard needed. The skill wraps it because
the raw command returns a live API key on stdout:

```bash
bash skills/using-agentmail/scripts/agentmail-signup.sh \
  --human-email you@example.com --username my-agent
# → a 6-digit code is emailed to you
bash skills/using-agentmail/scripts/agentmail-verify.sh --otp-code 123456
```

The signup script writes the credential to a `0600` file under
`~/.config/agentmail/` and prints only a masked fingerprint plus the path. Storing the
key is your call — the agent is told not to read that file back into the conversation.

Two things to know going in:

- **The OTP step needs a human.** The code expires in 24h and allows 10 attempts; once
  those are spent, even the correct code is rejected until it expires.
- **Until you verify, the agent can only email your own signup address.** Everything
  else fails `403 message_rejected`.

Full walkthrough: `skills/using-agentmail/references/onboarding.md`.

## Sending requires confirmation, deliberately

`allowed-tools` grants the read surface — list, get, search — and nothing that sends,
creates, updates, or deletes. Every mutating command falls through to a permission
prompt.

That is not an oversight, and broadening it to `Bash(agentmail *)` would remove the only
harness-level guard on an irreversible, outward-facing action. Two reasons it matters
here specifically:

1. **Email cannot be recalled.**
2. **There is no send idempotency available from the CLI.** `client_id` (exposed as
   `--client-id`) makes *resource creation* idempotent. Sends need an `Idempotency-Key`
   HTTP header, and the CLI has no flag for it — `--headers` sets *email* headers, not
   request headers. So a retried send can deliver a second real email, and the skill's
   rule is: never retry a send, check whether it landed instead.

`tests/safety_test.sh` fails if a send or delete verb appears in `allowed-tools`.

## What the skill covers

Inboxes, messages (send / list / get / search / raw), threads (per-inbox and org-wide),
replies and forwards, drafts including scheduled sends, labels as read/unread state, and
attachment **downloads**.

Deliberately out of scope for v0.1, named in the skill and routed to the docs: webhooks
and WebSockets (both need a public URL or a long-lived process, which is not something a
CLI skill should stand up), pods and multi-tenancy, custom domains and DNS verification,
allow/block lists, and attachment **sending** — the published docs and the installed
`--help` disagree about the flag syntax, so the skill says "probe it on a draft first"
rather than publishing a guess.

Receiving is polling-based via `inboxes:messages list`, which is the right fit for a CLI.

## Why this exists alongside AgentMail's official skill

AgentMail publishes its own skill (`npx skills add agentmail-to/agentmail-skills`) with
broadly similar coverage. This one is a different thing in four ways:

- **Dual-harness by contract** — behaves identically under Claude Code and Codex, with
  path-token, routing, and permission parity enforced by tests.
- **Permission-gated sends** — the confirmation gate above.
- **Secret-hygienic onboarding** — signup never puts an API key in the transcript.
- **Marketplace-distributed** — installs and updates with the rest of this repo's plugins.

Use whichever fits. They are not meant to be run together.

## Tests

```bash
bash plugins/agentmail/tests/skill-contract_test.sh   # dual-harness contract
bash plugins/agentmail/tests/safety_test.sh           # consent, secrets, send gate
bash plugins/agentmail/tests/preflight_test.sh        # script behavior vs. a stubbed CLI
```

All three run under `bash tests/run-all.sh`. Nothing touches the real API: the
behavioral suite stubs `agentmail` via `PATH` and redirects `HOME`/`XDG_CONFIG_HOME`
into a temp dir, so no real key is needed and no real credential file is touched.
