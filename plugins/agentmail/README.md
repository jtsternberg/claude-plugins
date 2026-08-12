# agentmail

Give an agent its own email address, and run a full round trip on it: create inboxes,
send, read what comes back, reply / reply-all / forward, and stage drafts for review.

Driven by the official [`agentmail` CLI](https://docs.agentmail.to/integrations/cli)
against the [AgentMail API](https://docs.agentmail.to) — an email API where every inbox
is an API resource, built for agents rather than people.

**Install:** `claude plugin install agentmail@jtsternberg`

Ships five skills and one hook. Invoke a skill as `/agentmail:<name>` in Claude Code,
`$agentmail:<name>` in Codex.

| Skill | For |
|---|---|
| `using-agentmail` | the hub — setup, keys, flags, errors, the whole command surface |
| `contacts` | the address book, and which addresses are actually verified |
| `check-mail` | what arrived, reading full bodies, triaging an inbox |
| `replying` | reply / reply-all / forward, draft-first for anything consequential |
| `relay-work-order` | handing work to (or taking it from) another agent over email |

The hook notices unread mail during a session. It does nothing until you turn it on — see
[Mail-check hook](#mail-check-hook).

**Codex availability caveat.** Everything here is built to the repo's dual-harness contract
and the hook is live-verified on Codex, but `agentmail` is not in this repo's Codex-native
marketplace catalog (`.agents/plugins/marketplace.json` lists three plugins), so
`codex plugin add agentmail@jtsternberg` does not resolve today. That is a repo-wide catalog
gap, tracked separately as beads claude-plugins-0way, not a property of this plugin.

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

To check what you have, without signing anything up:

```bash
bash scripts/agentmail-preflight.sh          # one API call; prints your inbox id
bash scripts/agentmail-preflight.sh --local  # offline: CLI + key presence only
```

Exit `0` means the key works — **including a key that is merely scope-limited**. An
inbox-scoped key cannot read organization details, and a `403 missing_permission` for
something out of scope is not a rejected credential. Exit `12` is reserved for a key that
is actually malformed, revoked, or rotated. `10` no CLI, `11` no key, `20` local-only OK,
`30` inconclusive (network/429/5xx).

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

## Contacts

An address book at `~/.config/agentmail/contacts.json` (mode `0600`), because AgentMail has
no contacts resource — zero hits for `contact` across the 82 paths in its OpenAPI spec, and
`Lists` are send/receive ACLs rather than an address book.

```bash
bash scripts/agentmail-contacts.sh init
bash scripts/agentmail-contacts.sh add --name "Some Agent" --email partner-agent@agentmail.to \
  --kind agent --verified-from "thread abc123, 4 messages"
bash scripts/agentmail-contacts.sh get "some agent"
```

Nothing is seeded and nothing personal ships in this repo. Two fields carry weight:
`verified_from` records *how* an address was confirmed, so an observed address stays
distinguishable from a remembered one, and `kind` (`human`/`agent`) defaults to `unknown`
rather than guessing, because it decides whether the relay protocol applies and who
approves a destructive action.

The store is never written into a repository, and the script takes no path flag.

## Mail-check hook

A `SessionStart` + `UserPromptSubmit` hook that mentions unread mail during a session. It is
**inert until you activate it** — installing the plugin does not start making network calls
before every prompt.

```bash
bash hooks/scripts/mail-check.sh --init                # remind mode (default)
bash hooks/scripts/mail-check.sh --init --mode auto     # also inject capped previews
rm ~/.config/agentmail/mail-check.json                  # off again
```

`remind` injects one line — count, inbox, newest subject, timestamp. `auto` adds truncated
previews under hard count and byte caps. Every tunable is in
[`references/mail-check.example.json`](references/mail-check.example.json); state lives at
`~/.cache/agentmail/mail-check-state.json`.

What it will not do: print or store the API key, fail a session (every unattended path
exits 0), call the API more than once per cooldown, or change inbox state — no labels, no
mark-as-read, no drafts. Missing CLI, missing key, bad config, API error, timeout: silent
no-op. It re-announces only when the newest unread message changes, or after
`renotify_after_minutes`, so ignored mail stops nagging.

### Harness differences

Both harnesses run the same `hooks.json` and the same script, and both inject the
`hookSpecificOutput.additionalContext` object it emits. That is live-verified on Claude Code
2.1.x and Codex CLI 0.147.0, not inferred — see
[`docs/codex/hooks-under-codex.md`](../../docs/codex/hooks-under-codex.md).

Two real differences:

- **Codex gates plugin hooks behind a trust prompt.** The first Codex session after
  installing this plugin is silent until you trust its hooks. That is Codex working as
  intended and the plugin does not try to work around it.
- **Claude Code replays saved injected text on `--resume`** rather than re-running the hook
  for past turns, so a stale notice can reappear in a resumed session. Every notice is
  timestamped for exactly this reason — treat it as a pointer, not a live count.

`Stop` is deliberately not used on either harness: Claude Code does not add `Stop` stdout to
context, and `Stop`'s `additionalContext` is documented as feedback that *continues* the
conversation, which would restart a turn the agent had just finished.

## What the skills cover

Inboxes, messages (send / list / get / search / raw), threads (per-inbox and org-wide),
replies and forwards, drafts including scheduled sends, labels as read/unread state,
attachment **downloads**, a local address book, inbox triage, and the agent-to-agent
work-order protocol.

Deliberately out of scope, named in the skills and routed to the docs: webhooks
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
bash plugins/agentmail/tests/skill-contract_test.sh   # dual-harness contract, every skill
bash plugins/agentmail/tests/safety_test.sh           # consent, secrets, send gate, guardrails
bash plugins/agentmail/tests/preflight_test.sh        # script behavior vs. a stubbed CLI
bash plugins/agentmail/tests/contacts_test.sh         # the contacts store
bash plugins/agentmail/tests/mail-check_test.sh        # the hook, including every silent path
```

All five run under `bash tests/run-all.sh`. Nothing touches the real API: the behavioral
suites stub `agentmail` via `PATH` and redirect `HOME`, `XDG_CONFIG_HOME`, and
`XDG_CACHE_HOME` into a temp dir, so no real key is needed and no real credential, contacts
file, or cache is read or written.

Skills and shell files are discovered by **glob**, not by a hardcoded list. That is not
style: moving the preflight to the plugin root silently dropped two safety assertions while
the suite still reported all-green, which is how a security check rots unnoticed.
