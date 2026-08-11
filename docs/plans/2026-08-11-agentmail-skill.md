# Build spec — `agentmail` plugin

**Date:** 2026-08-11
**Branch:** `agentmail-skill` (worktree `/Users/JT/Code/gittree-agentmail-skill`)
**Status:** approved 2026-08-11; built. This file reflects the approved edits and is the
source of truth. Review deltas are marked **[rev]**.

Ships one new plugin, `plugins/agentmail/`, with one skill that drives the official
`agentmail` CLI for a full round-trip email agent: setup, agent self-signup + OTP,
inboxes, send, receive, reply/reply-all/forward, drafts.

---

## 1. Grounding: what is verified vs. assumed

I did not take the CLI's command surface from the docs. I pulled
`agentmail-cli@0.7.14` from the npm registry, found it is a thin Node wrapper that
downloads a **Go binary from GitHub releases**, downloaded
`agentmail_0.7.14_macos_arm64.zip` into the session scratchpad, and ran `--help`
across every resource. Nothing was installed globally; no API call was made.

Captured output is at `/tmp/am-help-root.txt`, `/tmp/am-help-resources.txt`,
`/tmp/am-help-send.txt`, `/tmp/am-help-onboarding.txt`, `/tmp/am-help-2.txt`,
`/tmp/am-help-3.txt`. Docs pages are at `/tmp/fetch-docs-am-*.md`.

| Fact | Status |
|---|---|
| CLI v0.7.14, published 2026-07-15; repo pushed 2026-08-03 (unreleased work exists) | **verified** |
| `bin/agentmail` is a Node shim; real binary fetched from GitHub releases in `postinstall` | **verified** |
| Resource list: `agent inboxes inboxes:{drafts,messages,threads,lists,api-keys} pods pods:* webhooks api-keys domains drafts lists organizations threads` | **verified** |
| `--format` default is **`auto`**, not `json`; valid: `auto explore json jsonl pretty raw yaml` | **verified** (docs say json is default — docs are wrong) |
| `agent sign-up` flags: `--human-email --username --referrer --source` | **verified** |
| `agent verify` flags: `--otp-code` | **verified** |
| `inboxes:messages` has `send reply reply-all forward list get get-raw get-attachment update search` | **verified** |
| **No `--idempotency-key` on any send command** | **verified** — see §3.1 |
| `inboxes create` and `inboxes:drafts create` both have `--client-id` | **verified** |
| `organizations get` takes **no required flags** → cheapest auth probe | **verified** |
| **There is no `auth` resource in the CLI.** `agentmail auth --help` → "No help topic for 'auth'"; no `v0/auth` string in the binary | **verified** — see **[rev]** in §13 Q1 |
| Binary contains Stainless client internals (`x-should-retry`, `Retry-After-Ms`, `X-Stainless-OS`) → internal retry/backoff exists | **verified by string inspection**, behavior not observed |
| `agentmail help <cmd>` does **not** work; only `<cmd> --help` | **verified** |
| `@file` / `@file://` / `@data://` argument syntax, `\@` escaping, JSON/YAML body on stdin | **documented in the repo README only — not exercised live** |
| Docs' `--attachment.content` / `--attachment.filename` dotted flags | **contradicted by `--help`**, which shows only `--attachment value`. Needs a live probe before the skill documents attachments. |
| Homebrew tap `agentmail-to/homebrew-tap` exists (Casks dir, no Formula dir) | **exists, contents unverified** |
| **An invalid API key returns `403` with a bare `{"message":"Forbidden"}` — no `code`, no `fix`** | **verified live** against `api.agentmail.to`. Contradicts the errors doc's central claim that every error carries a machine-readable `code`, *and* the documented 401. Found during Phase 2; see §17. |

---

## 2. Design consequence of the `**CLI:**` bug

Most command descriptions in the installed binary are the literal string `**CLI:**`
— a docs-generation artifact where a Fern snippet marker replaced the description:

```
agentmail inboxes create - **CLI:**
agentmail inboxes:messages send - **CLI:**
```

Per-command `--help` still lists **flags** correctly. Only the prose is lost, and
resource-level listings (`agentmail inboxes --help`) are therefore near-useless.

This *strengthens* the `--help`-is-truth rule but changes where it points: the skill
must send the model straight to `agentmail <resource> <cmd> --help` for flags, and
must carry a small amount of **semantic** knowledge itself (what a command means, what
is irreversible, which arguments interact) because the CLI no longer supplies it. That
split — flags from `--help`, meaning from the skill — is the core authoring rule below.

---

## 3. Corrections to the work order

Five substantive items. The first is a safety issue.

### 3.1 `client_id` does not cover sends. Send idempotency is unreachable from the CLI.

The work order says "idempotency (`client_id`) handling". The docs split this in two
(`/tmp/fetch-docs-am-idempotency.md`):

- **Resource creation** (inboxes, drafts, webhooks) — body `client_id`. CLI exposes
  `--client-id`. Works.
- **Sends** (`messages.send`, reply, forward, `drafts.send`) — an **`Idempotency-Key`
  HTTP header**, because a send is irreversible.

`agentmail inboxes:messages send --help` has no such flag. `--headers` is *email*
headers placed into the message, not HTTP request headers. There is no
`--idempotency-key`, no `--max-retries`, no `--timeout`.

So the rule the skill must teach is the opposite of a retry loop:

> **Never retry a failed send.** You cannot make it idempotent from the CLI. On any
> ambiguous send failure (timeout, 5xx, killed process), verify with
> `agentmail inboxes:messages list --inbox-id <id> --limit 5 --format json` whether the
> message actually went out, and only then decide. If a guaranteed-once send matters,
> drop to `curl` with an `Idempotency-Key` header or use the SDK.

### 3.2 Sending email is irreversible and outward-facing — it needs a gate the work order doesn't mention

Nothing in the order covers confirmation before a send. Email cannot be recalled.
This skill will be model-invocable, so a misread request could mail a stranger.

Two mechanisms, both specified below (§7):

1. A **prose gate**: confirm recipient + subject + body with the user before any send
   to an address that isn't one of the org's own inboxes.
2. A **permission gate**: deliberately leave every sending and destructive command
   *off* `allowed-tools`, so Claude Code prompts on each one, while allowing the
   read/list/get/search/help surface to run freely.

Item 2 inverts the usual instinct to allowlist `Bash(agentmail *)`. It is the point,
and a test enforces it so nobody later "fixes" it by broadening.

### 3.3 The sign-up response *is* a live credential — it must never enter the transcript

`agent sign-up` returns `{api_key, inbox_id, organization_id}` on stdout. Running it
plainly writes a live API key into the conversation transcript. In this environment that
transcript is also auto-ingested into a local searchable index (mempalace `stop` /
`precompact` hooks), so "it's just my terminal" is not true.

The skill therefore never runs `agent sign-up` bare. A bundled script captures the JSON
to a `0600` file outside any repo and prints only masked values plus the path (§6).

### 3.4 Unverified orgs can only email the human's own address

`/tmp/fetch-docs-am-onboard.md:55`: until OTP verification completes, sends to any
other address fail `403 message_rejected`. This is the single most likely first-run
confusion — "I signed up, why won't it send?" — and the OTP step is human-in-the-loop,
so it can't be papered over. Onboarding must present verification as mandatory, not
optional, and the preflight must report verification state distinctly from "key valid".

### 3.5 `npm install -g agentmail-cli` is not the only install path, and the CLI's own error message is wrong

The npm package is a shim over a GitHub release binary. Options: `npm i -g agentmail-cli`,
a direct release download, or possibly the existing `agentmail-to/homebrew-tap`. All
require consent. Separately, `bin/agentmail` prints on failure:

```
Try reinstalling: npm install -g @agentmail/cli
```

`@agentmail/cli` is not a real package — the published name is `agentmail-cli`. A user
following that advice gets 404. Worth a line in Troubleshooting.

---

## 4. Directory layout

```
plugins/agentmail/
├── .claude-plugin/
│   └── plugin.json
├── README.md
├── skills/
│   └── using-agentmail/
│       ├── SKILL.md
│       ├── agents/
│       │   └── openai.yaml
│       ├── references/
│       │   ├── onboarding.md        # sign-up + OTP + key storage, full detail
│       │   └── recipes.md           # multi-step round-trip workflows
│       └── scripts/
│           ├── agentmail-preflight.sh
│           ├── agentmail-signup.sh
│           └── agentmail-verify.sh
└── tests/
    ├── skill-contract_test.sh
    ├── safety_test.sh
    └── preflight_test.sh
```

Single skill, so scripts live under `skills/using-agentmail/scripts/` and resolve via
`${CLAUDE_SKILL_DIR}` — not the plugin root. The plugin-root form is for *shared*
resources across sibling skills, which this plugin does not have.

**Frontmatter name: `using-agentmail`.** Matches the three existing CLI skills
(`using-cmux-cli`, `using-asana-cli`, `using-buddy-cli`). Invocation is
`/agentmail:using-agentmail` (Claude) and `$agentmail:using-agentmail` (Codex).
Bare `agentmail` would give the shorter `/agentmail:agentmail`; I chose consistency.
One-line call for the boss if you disagree.

---

## 5. SKILL.md frontmatter

```yaml
---
name: using-agentmail
description: "Sends and receives email for an AI agent via the AgentMail API and the `agentmail` CLI — create inboxes, send mail, read incoming messages and threads, reply / reply-all / forward, manage drafts, and run the agent self-signup + OTP verification flow."
when_to_use: "Use when the user wants an agent to have its own email address or to act on email: sign up for AgentMail, create or list inboxes, send an email, check for new mail, read a message or thread, reply or forward, prepare or send a draft, or schedule a send. Also use when AgentMail setup is failing — missing CLI, missing or invalid AGENTMAIL_API_KEY, or a 403 that mentions verification."
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
  - "Read"
---
```

`description` carries the Codex routing terms (Codex ignores `when_to_use`): *email,
send, inbox, reply, forward, draft, AgentMail, OTP*. `when_to_use`, `argument-hint`,
and `allowed-tools` are Claude-only and additive.

**Deliberately absent from `allowed-tools`, so each prompts:** `inboxes:messages
send|reply|reply-all|forward|update`, `inboxes:drafts create|update|delete|send`,
`inboxes create|update|delete`, `inboxes:threads delete`, `threads delete`, `agent
sign-up`, `agent verify`, every `api-keys`, `domains`, `webhooks`, `lists`, `pods`
verb, and the two scripts that transmit or handle credentials
(`agentmail-signup.sh`, `agentmail-verify.sh`). SKILL.md states this is intentional
and why; `safety_test.sh` fails if a send or delete verb appears in `allowed-tools`.

**No `disable-model-invocation`** — the skill *should* fire on "send an email". So no
`policy.allow_implicit_invocation: false` is required. `agents/openai.yaml` carries
interface metadata only:

```yaml
interface:
  display_name: AgentMail
  short_description: Send and receive email for an agent via the AgentMail CLI
```

Open question for the boss: whether the interface-only `openai.yaml` is wanted at all
when no policy override is needed. It is harmless; I'd include it for display polish.

---

## 6. SKILL.md body outline

Shape follows `using-cmux-cli`: golden rule up front, live `!` context, thin
vocabulary, deep material in `references/`.

1. **Title + one-paragraph scope.** AgentMail specifically — not Gmail (that's `gws`),
   not SMTP.
2. **The golden rule, split.** Flags come from `agentmail <resource> <cmd> --help`,
   never from this file. Meaning, irreversibility, and argument interactions come from
   this file, because the installed CLI's descriptions are the literal string
   `**CLI:**` (§2).
3. **Live context — exactly one Claude `!` block.** **[rev]** The version check folds
   into the script; there is no second block and no compound shell operator anywhere in
   it. A block containing `&&`, `||`, `|`, or `;` trips Claude Code's shell-operator
   permission gate at load time — the same reason `fetch-docs` routes its `--check`
   through a script instead of an inline `(cmd && echo) || echo`. Multiple *lines* are
   fine (fetch-docs' own block does an assignment then an invocation); operators are not.

   ```!
   # Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
   SKILL_DIR="${CLAUDE_SKILL_DIR}"
   bash "$SKILL_DIR/scripts/agentmail-preflight.sh" --local
   ```

   `--local` reports CLI presence, CLI version, and whether `AGENTMAIL_API_KEY` is set,
   printing a masked fingerprint only. **No network call and no `organizations get` at load time**
   — an API round-trip on every skill load costs latency and quota, and would print
   org/inbox identifiers into context for tasks that never touch them. The
   authenticated probe is a separate explicit step. Calling that out because it is a
   deliberate divergence from `using-cmux-cli`, which does hit its socket at load.
4. **Codex note on `!` blocks.** Codex does not execute them; it must run the preflight
   script explicitly as its first step. Stated in prose adjacent to the blocks.
5. **Setup.** Three states and what to do: CLI missing → offer install, never run it
   (§8); key missing → §7 onboarding or console key; key present → authenticated probe
   `agentmail organizations get --format json`.
6. **Onboarding: sign-up → OTP → verify.** Summary here, full detail in
   `references/onboarding.md`.
7. **The send gate.** §7 below. Placed before the command surface on purpose.
8. **Command surface grouped by task.** §9 below.
9. **Reading mail well.** `extracted_text` / `extracted_html` for new content without
   quoted history; `html` is primary and `text` may be absent entirely on
   Gmail/Outlook forwards; labels as read/unread state (there is no mark-as-read
   endpoint); `--include-spam|trash|blocked|unauthenticated` when a message is missing.
10. **Errors, rate limits, idempotency.** §10 below.
11. **Output and parsing.** Always `--format json`; the default is `auto`. `--transform`
    takes GJSON, `-r` unquotes strings. Repo convention: save raw output to a file and
    parse the file — never pipe straight into `jq`.
12. **Quoting and `@`.** `@`-leading arguments load a file (`@file://` string,
    `@data://` base64); escape a literal leading `@` as `\@`. Email addresses are not
    `@`-leading so `--to user@example.com` is fine — flagged for live confirmation
    (§13). Heredoc JSON/YAML body for multi-line HTML bodies, marked unverified until
    probed.
13. **Troubleshooting.** Not on PATH; the wrong `@agentmail/cli` reinstall hint (§3.5);
    `403` before verification; `not_found` that is really a scope or label-permission
    denial; `resource_taken` on username; `domain_not_verified`;
    `agentmail help <cmd>` doesn't exist.
14. **Everything else (vocabulary only).** `webhooks`, `domains`, `lists`, `pods`,
    `api-keys`, `organizations`, WebSockets. Named so the model knows they exist;
    signatures via `--help`.

---

## 7. The send gate

Stated as an affirmative rule in SKILL.md:

> **Before any command that sends mail — `send`, `reply`, `reply-all`, `forward`,
> `drafts send` — show the user the exact recipients (`to`/`cc`/`bcc`), subject, and
> body, and get explicit confirmation.** One confirmation covers one send, not a
> session. Email cannot be recalled and there is no CLI-level idempotency to make a
> retry safe (§3.1).

Three supporting rules:

- **Prefer the draft-first path** for anything the user hasn't dictated verbatim:
  `inboxes:drafts create --client-id <stable-id>` → show it → `inboxes:drafts send`.
  `--client-id` makes the *create* half idempotent, and the draft is a reviewable
  artifact. This is also what AgentMail's own human-in-the-loop guidance recommends.
- **`reply-all` needs a recipient count first.** `agentmail inboxes:messages reply-all`
  takes no `--to/--cc/--bcc` (the API forbids explicit recipients with `reply_all`), so
  the blast radius is whatever is on the thread. Read the thread and tell the user how
  many addresses will receive it before sending. Cap is 50 recipients per send.
- **Sending to the human's own signup address is the safe rehearsal.** On an unverified
  org it's the *only* thing that works (§3.4), and it's the right first test after setup.

The permission-gate half is in §5. Both halves are needed: prose alone is advisory, and
the permission prompt alone doesn't show the user the body.

---

## 8. Install consent

Mirrors `fetch-docs`' global-install rule.

- **Never run `npm install -g`, `npm i -g`, `brew install`, or a release download
  without explicit user consent.** No script in this plugin invokes an installer;
  `safety_test.sh` enforces that.
- When the CLI is missing, present the options and stop: `npm install -g agentmail-cli`
  (official), or a direct GitHub release binary, or a possible Homebrew tap. Note that
  the npm path runs a `postinstall` that downloads a binary from GitHub releases, so it
  needs network and GitHub reachability — a plain npm mirror is not enough.
- `npx agentmail-cli` is a plausible no-global-install path but pays the binary
  download per cold cache. Mention as an option, don't default to it.

---

## 9. Command surface, grouped by task

Table of *task → command*, with flags from `--help`. Deliberately no flag lists except
where a flag is semantically load-bearing and easy to get wrong.

| Task | Command |
|---|---|
| Am I authenticated? | `organizations get` (no required flags) |
| Sign up an agent | `agent sign-up --human-email --username` — via script, §6 |
| Verify OTP | `agent verify --otp-code` — via script |
| Create / list / get inbox | `inboxes create|list|get` (`create` takes `--client-id`, `--username`, `--domain`, `--display-name`, `--metadata k=v`) |
| Send new mail | `inboxes:messages send --inbox-id --to --subject --text --html` |
| Read inbox | `inboxes:messages list --inbox-id` (`--label`, `--from`, `--to`, `--subject`, `--before`, `--after`, `--limit`, `--include-*`) |
| Read one message | `inboxes:messages get` / `get-raw` (presigned `.eml` URL) |
| Search | `inboxes:messages search --q` / `threads search` (limit ≤ 100) |
| Reply | `inboxes:messages reply --message-id` (or `reply-all`) |
| Forward | `inboxes:messages forward --message-id --to` |
| Label / mark read | `inboxes:messages update --add-label --remove-label` |
| Threads | `inboxes:threads list|get|search`, org-wide `threads list|get|search` |
| Drafts | `inboxes:drafts create|update|get|list|send|delete` (`--in-reply-to`, `--forward-of`, `--reply-all`, `--send-at`, `--client-id`) |
| Attachments | `inboxes:messages get-attachment`, `inboxes:threads get-attachment` |
| Org-wide review | `threads list`, `drafts list` — note **there is no org-wide messages list** |

Semantic notes that `--help` cannot give (this is the payload of §2):

- `reply` has both a `reply-all` sibling command and a `--reply-all` boolean. Prefer
  the explicit `reply-all` command so the intent is legible in the transcript.
- `in_reply_to` and `forward_of` are mutually exclusive on a draft, and a draft's kind
  is fixed at creation — "make this a reply" means create a new draft.
- `--send-at` auto-applies the `scheduled` label; `--send-at null` unschedules;
  a draft in `sending` state returns 409 on edit.
- `inboxes:threads delete` and `threads delete` are **permanent**, including every
  message in the thread. No undo.
- `inboxes create --username` collisions return `resource_taken`, not a 400.

---

## 10. Errors, rate limits, idempotency

- **Branch on `code`, never on `name` or `message`.** AgentMail keeps legacy
  `name`/`message` values for compatibility (a permission denial still reads
  `Forbidden`); `code` and `fix` carry the actual cause and remedy. Every error also
  ships a `docs` URL. Read `fix` back to the user — it is usually the answer.
- **429 `rate_limit_exceeded`:** honor `Retry-After`. The binary carries Stainless
  retry internals (`x-should-retry`, `Retry-After-Ms`), so the CLI likely already
  retried before you saw the error. Do **not** add your own retry loop around a send
  (§3.1). For reads, wait the advertised interval and retry once.
- **Idempotency:** `--client-id` on `inboxes create` and `inboxes:drafts create`.
  Nothing for sends. Full rationale in §3.1, and it belongs verbatim in SKILL.md.
- Error codes worth naming with their real cause: `not_found` (may be a scope or
  restricted-label denial, not a bad ID), `message_rejected` (block/allow list,
  unverified org, or unfetchable attachment URL), `limit_exceeded` on OTP attempts
  (the exhausted code stays live and rejects even the correct code until it expires
  24h after issue), `conflict` (idempotency-key collision), `domain_not_verified`.

---

## 11. Bundled scripts

All three are POSIX-ish bash, `set -uo pipefail`, no installers, no network beyond the
`agentmail` binary itself. Each is invoked through the runtime-resolved skill path with
the assignment repeated in every independently executed block:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/agentmail-preflight.sh"
```

### `agentmail-preflight.sh`

`--local` (offline) or default (adds one authenticated probe).

Prints a short human-readable report and exits with a distinct code so the model can
branch without parsing prose:

**[rev]** Exit codes, with the "unverified org" probe removed — the API surfaces no
verification field, so it cannot be detected pre-send (§13 Q1):

| Exit | Meaning |
|---|---|
| 0 | CLI present, key set, key accepted. **Verification state unknown** |
| 10 | CLI not on PATH |
| 11 | CLI present, `AGENTMAIL_API_KEY` unset |
| 12 | Key set but rejected (401 `unknown_api_key` / `unauthorized` / `missing_authorization` / `invalid_token_type`) |
| 20 | `--local`: CLI present and key set (all an offline check can know) |
| 30 | **[rev, added]** CLI and key present but the probe failed for another reason — network, 429, 5xx. Reachability unknown, *not* a bad key. Added so a network blip is never reported as a bad credential. |

Never prints the key. Reports a masked fingerprint only — a short prefix plus the last
four (`am_us_…a1b2`), enough to tell two keys apart and not enough to use.

The authenticated probe is `agentmail organizations get --format json`; exit 0 vs 12 is
decided by whether the CLI accepted the credential, not by any field in the payload.
Where a *positive* verification signal exists, it is local only: `agentmail-verify.sh`
records `verified: true` to its state file on a successful verify, and the preflight
surfaces that as a hint when present. Absence of the hint means unknown, never
"unverified".

### `agentmail-signup.sh`

`--human-email <addr> --username <name> [--out <path>]`

1. Refuse to run if `AGENTMAIL_API_KEY` is already set, unless `--force` — sign-up is
   idempotent per docs but **rotates the API key**, which silently invalidates the key
   already in the environment. That footgun deserves a guard.
2. Run `agentmail agent sign-up --human-email … --username … --source agentmail-cli
   --format json`, capturing stdout to a variable, never to the terminal.
3. Write raw JSON to `${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/signup-<utc>.json`
   under `umask 077`, `chmod 600`. Outside any repo by construction — never a project
   `.env`, never the worktree.
4. Print only: `inbox_id`, `organization_id`, masked key fingerprint, the file path, and
   the next step ("check <human-email> for a 6-digit code, then run the verify script").
5. Print how to persist the key from that file into the user's own secret store, and
   note the file holds a live credential and can be deleted after.

The model is instructed **not to `Read` that file**. It doesn't need to: the verify
script consumes it, and the key belongs in the user's shell profile or password
manager, which is the user's action, not the agent's.

### `agentmail-verify.sh`

`--otp-code <6 digits> [--key-file <path>]`

Sources the key from the newest `signup-*.json` (or `--key-file`, or an already-set
`AGENTMAIL_API_KEY`), exports it only within its own process, runs `agentmail agent
verify --otp-code … --format json`, prints the result, and on success prints the
reminder that the key still needs persisting into the user's environment. Validates the
OTP is exactly six digits locally first, because a wasted attempt is costly.

**[rev]** OTP facts to carry in `references/onboarding.md`: the code **expires 24h**
after issue, allows a **maximum of 10 attempts**, and attempt exhaustion rejects even
the correct code until the code expires (`limit_exceeded`). If the OTP email never
arrives, the human can instead create an account at
[console.agentmail.to](https://console.agentmail.to) using the same human email.

On success the script records `{"verified": true, "verified_at": "<utc>"}` to
`${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/state.json` (mode 600). That is the only
positive verification signal available anywhere (§13 Q1), and the preflight surfaces it
as a hint.

---

## 12. Dual-harness compliance checklist

Each row is a contract from `AGENTS.md § Dual-Harness Skill Contract`.

| Contract | How this spec satisfies it |
|---|---|
| Skill at `plugins/<plugin>/skills/<name>/SKILL.md` | `plugins/agentmail/skills/using-agentmail/SKILL.md` |
| Codex routing terms in `description` | §5 — email/send/inbox/reply/forward/draft/AgentMail/OTP all in `description`, not only `when_to_use` |
| Bare `${CLAUDE_SKILL_DIR}` tokens, no shell-default wrappers | every script block; no `${VAR:-default}` around the token |
| Codex substitution prose adjacent, token not repeated in it | the `# Codex:` comment names the directory, never the token |
| Assignment repeated in every independently executed block | yes — each fenced block re-assigns `SKILL_DIR` |
| No `${CLAUDE_SKILL_DIR}/../../` traversal | scripts live under the skill; no plugin-root resources |
| No bare relative paths in prose | `references/*.md` referenced through a resolvable path with Codex prose |
| `disable-model-invocation` mirrored in `agents/openai.yaml` | not used; `openai.yaml` has no `policy` block, and §5 says why |
| `allowed-tools` synchronized with commands actually run | §5 enumerates; `skill-contract_test.sh` asserts it, `safety_test.sh` asserts sends stay out |
| `!` dynamic context treated as Claude-only | §6.4 — Codex runs the preflight script explicitly instead |
| `$ARGUMENTS` literal where positional interpolation matters | not used; the skill takes freeform intent via `argument-hint`. Nothing to preserve. |
| Version bumped once, at the end | `plugin.json` starts at `0.1.0`; no bump during iteration |

Phase 2 will run `validate-dual-harness-skill` against the new skill plus
`bash plugins/codex/tests/skill-paths_test.sh`,
`node --test plugins/codex/tests/compatibility.test.mjs`, and `bash tests/run-all.sh`.

---

## 13. Open questions — resolved at review

**Q1. Org verification state — RESOLVED, and it removed a feature.** The API surfaces no
verification field: `organizations get` returns counts/limits/billing/authentication_*,
and `GET /v0/auth/me` returns scope fields. The `agent_unverified → agent_verified`
transition is real (it removes the send allowlist) but is not readable from any
documented GET. So the exit-13 pre-send probe is dropped and §11 is renumbered. What the
skill teaches instead: after signup, the first send **must** go to the human's own signup
address, and a `403 message_rejected` to any other recipient is *the* signal the org is
still unverified. `agentmail-verify.sh` records `verified: true` locally on success —
the only positive signal that exists.

**Q1b. `agentmail auth me` — the review's suggested probe does not exist. [rev, pushback]**
The review asked to swap the probe to `agentmail auth me` as the purpose-built identity
call. `GET /v0/auth/me` exists in the HTTP API, but **CLI v0.7.14 does not surface it**:
there is no `auth` resource in the root command list, `agentmail auth --help` returns
"No help topic for 'auth'", and the binary contains no `v0/auth` string (`v0/api-keys`,
`v0/webhooks`, `v0/agent/verify` and friends are all present, so the absence is
meaningful, not a strings artifact). `allowed-tools` therefore keeps
`Bash(agentmail organizations get*)` and the preflight calls `organizations get`. Worth
revisiting when a CLI release adds the resource — the skill's `--help`-is-truth rule
means that costs nothing to adopt later. The rest of Q1 stands as approved.

**Q2. Attachments — deferred as proposed.** Sending attachments is v0.2; SKILL.md says
"run `--help` and probe on a draft first" rather than publishing the unverified dotted
syntax. Receiving via `get-attachment` stays in v0.1.

**Q3. `allowed-tools` prefix matcher — confirmed at review.** Prefix+glob, so
`Bash(agentmail inboxes:messages list*)` matches while `send`/`reply`/`forward` match
nothing and prompt. Fallback note retained.

**Q4. `--to user@example.com`** — only a *leading* `@` triggers file-load, so recipients
are safe. One live probe in Phase 2; non-blocking.

**Q5. Heredoc JSON/YAML body** — unconfirmed, so SKILL.md prefers `--text`/`--html`
flags and marks the heredoc as unverified.

**Q6. Frontmatter name** — `using-agentmail`, approved.

**Q7. Official AgentMail skill** — README states why ours exists (dual-harness,
permission-gated, secret-hygienic, marketplace-distributed). Non-blocking skim.

**Q8. Webhooks / WebSockets** — vocabulary only, routed to docs. Polling via
`inboxes:messages list` is the right fit for a CLI skill.

---

## 14. Registration

**`plugins/agentmail/.claude-plugin/plugin.json`**

```json
{
  "name": "agentmail",
  "description": "Give an agent its own email address. Send and receive email through the AgentMail API via the official agentmail CLI: create inboxes, send mail, read incoming messages and threads, reply / reply-all / forward, manage and schedule drafts, and run the agent self-signup and OTP verification flow. Triggers on mentions of AgentMail, agent email, inbox creation, sending or checking email for an agent.",
  "version": "0.1.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" }
}
```

**`.claude-plugin/marketplace.json`** — append to `plugins` (28th entry), keeping the
file's two-key shape:

```json
{ "name": "agentmail", "source": "./plugins/agentmail" }
```

**Root `README.md`** — one entry under `## Plugins` → `### Skills`, matching the
existing `#### <emoji> [name](path)` + one-line description + `**Install:**` form:

```markdown
#### 📬 [agentmail](plugins/agentmail)
Give an agent its own email address — send, receive, reply, forward, and draft mail through the AgentMail API.

**Install:** `claude plugin install agentmail@jtsternberg`
```

**`plugins/agentmail/README.md`** — install, `AGENTMAIL_API_KEY` setup, the signup/OTP
flow, an explicit "sends require confirmation and are not on the allowlist by design"
note, and the §13.7 note on the official AgentMail skill.

**Version bump:** `0.1.0` is the initial value, not a bump. No further bump until the
change-set is complete.

---

## 15. Test plan

Three bash suites at `plugins/agentmail/tests/*_test.sh` — a glob-discovered path in
`tests/run-all.sh`. Each prints `N passed, M failed` and exits non-zero on failure. No
suite touches the network or a real API key; `preflight_test.sh` stubs `agentmail` via
`PATH`, following the `handoff` (stubs `bd`) and `cmux` suites' convention.

### `skill-contract_test.sh` — dual-harness contract

1. `SKILL.md` exists at the discoverable path; frontmatter has `name`, `description`,
   `when_to_use`, `argument-hint`, `allowed-tools`.
2. Every bare `${CLAUDE_SKILL_DIR}` occurrence is unwrapped — no `${CLAUDE_SKILL_DIR:-…}`.
3. No `${CLAUDE_SKILL_DIR}/../` traversal anywhere.
4. Every fenced block that uses `$SKILL_DIR` also assigns it in that same block.
5. Every `SKILL_DIR` assignment has a `# Codex:` substitution comment adjacent, and
   that comment does not itself contain the path token.
6. Every `agentmail …` command in an executable block is covered by an `allowed-tools`
   pattern **or** appears on the intentional prompt-on-use list (§5) — the sync check
   the contract asks for, in both directions.
7. `agents/openai.yaml` parses, and has no `policy` block while SKILL.md has no
   `disable-model-invocation` (the mirror rule, checked in the negative direction).
8. Every `references/*.md` mentioned in SKILL.md exists.

### `safety_test.sh` — the rules that matter if someone edits carelessly

1. No script contains `npm install`, `npm i `, `brew install`, `curl … | sh`, or a
   release download. Consent rule, enforced mechanically (§8).
2. No script echoes an unmasked key: no `echo`/`printf` of a variable named
   `*api_key*`/`*API_KEY*` without a masking transform; `agent sign-up` never appears
   without output capture.
3. Every credential file write is preceded by `umask 077` or followed by `chmod 600`,
   and no script writes to a path matching `*/.env`.
4. No literal `am_`-prefixed key-shaped string in any committed file.
5. `allowed-tools` contains no `send`, `reply`, `reply-all`, `forward`, `delete`,
   `create`, `update`, `sign-up`, or `verify` verb. This is the §3.2 gate; the test
   exists so a future "portability fix" that broadens it fails loudly.
6. SKILL.md contains no retry-loop guidance around a send, and does contain the
   verify-before-you-conclude rule from §3.1.

### `preflight_test.sh` — script behavior against a stubbed CLI

A fake `agentmail` earlier on `PATH`, driven by an env var, produces each scenario;
the suite asserts exit code and that output is masked.

| Scenario | Assert |
|---|---|
| no `agentmail` on PATH | exit 10, message names the install options, runs no installer |
| CLI present, key unset | exit 11, points at onboarding |
| stub returns 401 `unknown_api_key` | exit 12 |
| stub returns an unverified org | exit 13, message names the signup-address restriction |
| stub returns a verified org | exit 0 |
| `--local` with CLI + key | exit 20, no stub invocation recorded (proves no network) |
| any run with a key set | stdout/stderr never contain the full stub key |
| `agentmail-signup.sh` with `AGENTMAIL_API_KEY` already set | refuses without `--force`, names key rotation |
| `agentmail-signup.sh` happy path (stubbed) | JSON file is mode `600`, outside the repo; stdout has the masked fingerprint and the path, not the key |
| `agentmail-verify.sh --otp-code 12x4` | rejected locally, stub never called |

Phase 2 gate: `bash tests/run-all.sh` green with the skip count read, not just the exit
code; plus the three dual-harness commands in §12; plus `validate-dual-harness-skill`.

---

## 16. Out of scope for v0.1

Named in SKILL.md vocabulary, routed to the docs, not implemented: webhooks and
WebSockets (need a public URL / long-lived process), pods and multi-tenancy, custom
domains and DNS verification, allow/block lists, scoped API-key creation, IMAP/SMTP,
and attachment *sending* pending §13.2. Receiving is polling-based via
`inboxes:messages list`, which is the right fit for a CLI skill.

---

## 17. Phase 2 build notes

Built as specified with the reviewed edits. Two things are worth recording because they
changed the code rather than just confirming it.

### The `code`-less 403 (a real bug, caught by probing the live API)

The errors doc opens with "Every error response from the AgentMail API includes a stable,
machine-readable `code`", and the skill was written to branch on it. One unauthenticated
GET with a deliberately invalid key showed otherwise:

```
GET "https://api.agentmail.to/v0/organizations": 403 Forbidden
{ "message": "Forbidden" }
```

No `code`, no `fix`, and **403 where the docs document 401**. The first version of
`agentmail-preflight.sh` looked for `unknown_api_key` and therefore classified a plainly
bad key as exit 30 "inconclusive — network, 429, or server error", which would send a user
hunting a network fault they do not have.

Fixed by classifying on the HTTP status the CLI prints to stderr (`401`/`403` → 12,
`429`/`5xx`/none → 30), with the `code` check kept as a refinement and
`missing_permission` given its own remedy text. `preflight_test.sh` now carries a stub
reproducing the exact live shape, so the regression cannot come back. SKILL.md's error
section documents the caveat.

This is the clearest argument for the §1 methodology: the bug was invisible to every
static read of the docs, and one real call surfaced it.

### Test-harness false positives (worth knowing before editing the suites)

`safety_test.sh` initially failed four checks, all of them harness bugs rather than
defects, and all four are the sort of thing that gets "fixed" by weakening the assertion:

1. The preflight **prints** `npm install -g agentmail-cli` as advice inside a heredoc. A
   grep for installer commands read it as an invocation. Fixed by stripping heredoc bodies
   in `exec_lines()`, not by dropping the check.
2. SKILL.md and onboarding.md say "**never** run `agentmail agent sign-up` directly". A
   grep for uncaptured sign-up calls matched the prose forbidding it. Fixed by scoping
   shell checks to `.sh` files and doc checks to fenced bash blocks, and by *adding* a
   check that the prohibition is present.
3. The stub key `am_us_STUBKEY…` matched the committed-secret regex. Fixed by exempting
   literals that label themselves (`STUB`/`FAKE`/`EXAMPLE`/`PLACEHOLDER`), so the guard
   still catches an unlabelled one.
4. Two phrase assertions failed because markdown line-wrapping split the phrase across a
   newline. Fixed with a `has_phrase()` helper that flattens whitespace first.

Anyone adding checks to these suites should reuse `exec_lines()`, `has_phrase()`, and
`md_bash_blocks()` rather than reaching for bare `grep` — each exists because a bare grep
gave a confident wrong answer.

### Verification actually performed

| Check | Result |
|---|---|
| `bash tests/run-all.sh` | 31 passed, 0 failed, 1 skipped (`codex: live-plugin`, opt-in on `CODEX_LIVE=1`, pre-existing) |
| `plugins/agentmail/tests/skill-contract_test.sh` | 30 passed |
| `plugins/agentmail/tests/safety_test.sh` | 30 passed |
| `plugins/agentmail/tests/preflight_test.sh` | 53 passed |
| `bash plugins/codex/tests/skill-paths_test.sh` | 13 passed |
| `node --test plugins/codex/tests/compatibility.test.mjs` | 5 passed |
| Codex-shaped invocation: every script run by absolute path, from an unrelated cwd, with `CLAUDE_SKILL_DIR` unset | all correct |
| Real CLI v0.7.14: version parsing, exit 11, exit 12 against the live API | all correct |

**Not performed:** the live Codex plugin probe (`CODEX_LIVE=1`) needs `OPENAI_API_KEY` and
paid calls, and targets the `codex` plugin rather than this one; and no installed-plugin
probe was run under either harness, since installing mutates the user's Claude/Codex
config. Both are the remaining gap against §12 item 3 and need a human's go-ahead.

### Open decision left for the boss

`.agents/plugins/marketplace.json` (the Codex-native catalog) is keyed off
`.codex-plugin/plugin.json`, which only 2 of 28 plugins ship. `agentmail` has only
`.claude-plugin/plugin.json`, so it appears in the legacy catalog alone — consistent with
the other 25 dual-harness plugins, and the catalog-consistency test passes either way.
Adding native Codex distribution is a separate call that was not in the approved spec, so
it was not made unilaterally.
