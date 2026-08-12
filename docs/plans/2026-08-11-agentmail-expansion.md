# AgentMail expansion: contacts, mail-check hooks, four new skills

**Status:** approved 2026-08-11 (§7); built 2026-08-11. Deviations from the plan are
marked inline — §1 consequence 1, §1.5 (withdrawn), §1.6 (new), §3, §4 Codex gaps.
**Branch:** `agentmail-expansion` (worktree `/Users/JT/Code/gittree-agentmail-expansion`)
**Plugin version:** stays `0.1.0` through testing. The release bump must document the
preflight exit-code change — §7 Q5, tracked as claude-plugins-hyuk.
**Addresses:** redacted. `<claude-inbox>`, `<partner-agent>`, `<partner-alt>`.

Adds an address book, a periodic unread-mail notice that works in both harnesses, and
four skills, to the existing `agentmail` plugin. No new plugin, so
`.claude-plugin/marketplace.json` is untouched.

---

## 1. Research findings (all verified, not assumed)

### AgentMail has no native contacts. Local store it is.

Three independent checks, all negative:

| Source | Probe | Result |
|---|---|---|
| Docs index | `grep -i contact` over `docs.agentmail.to/llms.txt` (57 pages) | 0 hits |
| API reference | `grep -c contact` over `docs.agentmail.to/openapi.json` (82 paths) | **0** |
| CLI 0.7.14 | `agentmail --help` top-level resource list | 22 resources, no `contacts` |

The nearest native thing is **Lists** (`lists`, `inboxes:lists`, `pods:lists`) — six
send/receive/reply × allow/block ACLs whose entries are an address-or-domain plus an
optional `reason`. They carry no name, no role, no notes, and writing one changes what the
inbox is *allowed to talk to*. Using a security control as an address book would mean a
"remove a contact" gesture silently altering deliverability. Rejected.

Also rejected: **inbox `metadata`**. It merges on `inboxes update`, which is a mutation on
a resource JT's key may not be scoped to write, it is bounded and untyped, and it puts
personal addresses on a remote object for no gain over a local file.

### The known-contact ambiguity is resolved: `<partner-agent>@agentmail.to`

Addresses are redacted throughout this document (Q1) — the real values live only in the
local contacts store on JT's machine. The evidence below is message counts and thread
structure, which survives redaction intact.

Read-only `inboxes:messages list` on `<claude-inbox>` returned 6 messages:

```
2026-08-11T21:21:29Z  JT's ChatGPT     <partner-agent>  -> <claude-inbox>   [received,unread]  Re: Hello from Claude
2026-08-11T20:42:11Z  JT's Claude Code <claude-inbox>   -> <partner-agent>  [sent]             Re: Hello from Claude
2026-08-11T20:32:46Z  JT's ChatGPT     <partner-agent>  -> <claude-inbox>   [received,unread]  Re: Hello from Claude
2026-08-11T20:29:42Z  Justin Sternberg me@jtsternberg.com -> <claude-inbox> [received,unread]  Re: Claude's inbox is live
2026-08-11T20:29:32Z  JT's Claude Code <claude-inbox>   -> <partner-agent>  [sent]             Hello from Claude
2026-08-11T20:27:21Z  JT's Claude Code <claude-inbox>   -> me@jtsternberg.com [sent]          Claude's inbox is live
```

`<partner-agent>` is verifiable — four messages, one live thread
(`019def1e-8402-47d2-b606-fdcef4019608`). `me@jtsternberg.com` is verifiable — it sent
mail in. `<partner-alt>` is **not** verifiable from here and must not be seeded as
fact: it appears in no message, and an inbox-scoped key cannot enumerate other inboxes
(`inboxes list` returns exactly one, `count: 1`). A full-text search for it returned one
hit, but reading that message's body shows the match came from tokenizing the shared
inbox-name prefix, not from the address.

`<partner-alt>` is real, though — JT said verbally (session bd2a8174) that it is ChatGPT's
**original** inbox and that `<partner-agent>` came later and is the one on the wire. So the
seed records it as an unverified alternate on the ChatGPT contact, provenance stated as
JT-verbal rather than observed, and never usable for a send until JT confirms it.

### The protocol in the work order is the protocol on the wire

Reading the full body of the sent message `<0100019ff28fb29a-…>` confirms the tags
(`[HANDOFF] [FYI] [ASK] [DONE]`), the four-line `Goal:/Context:/Needed:/Refs:` body, the
FYI exemption, and both guardrails were proposed by this side and codified by ChatGPT's
agent as its `collaborate-with-claude-via-agent-email` skill. The relay skill transcribes
that agreement rather than inventing one, and the thread is cited in the skill as its
source of truth.

### Both harnesses can inject context, with the same wire format

| | Claude Code 2.1.x | Codex 0.147.0 |
|---|---|---|
| Plugin `hooks/hooks.json` | supported | supported (verified in `docs/codex/hooks-under-codex.md`) |
| `SessionStart` + matcher | supported | supported, matcher enforced |
| `UserPromptSubmit` | supported, **no matcher** | declared in `config.schema.json` |
| stdout → context | yes on `SessionStart`/`UserPromptSubmit` only | **yes** — live-probed, see below |
| `hookSpecificOutput.additionalContext` | yes | **yes** — same field, same casing |
| `${CLAUDE_PLUGIN_ROOT}` in a hook command | supported | supported |
| `timeout` | honored (UserPromptSubmit default drops to 30s) | honored |
| Runs on first install | yes | **no — trust gate** |

The decisive evidence for Codex is `codex-rs/hooks/schema/generated/`
`user-prompt-submit.command.output.schema.json` and `session-start.command.output.schema.json`
on `openai/codex@main`: both declare `hookSpecificOutput.additionalContext` (string) with
`additionalProperties: false`.

Two consequences drive the design:

1. **Emit JSON.** It is the explicitly specified channel on both harnesses, and it is the
   only one that also carries `hookEventName` and `suppressOutput`. One object is valid on
   both, which is why this hook is one script rather than two.

   *Corrected after building:* the spec originally justified this as *necessary* — reasoning
   that Codex's `additionalProperties: false` made plain stdout a non-channel there. **A
   live probe disproved that** (§1.6): plain text on stdout reaches the model under Codex
   too. So JSON is the better choice, not the only working one, and finding §1.5 below was
   wrong. Schema shape is not a statement about what the harness does with non-JSON output,
   and inferring one from the other was the mistake.
2. **`Stop` is the wrong event.** Claude Code does not add `Stop` stdout to context, and
   `Stop`'s `additionalContext` is explicitly *"non-error feedback that continues the
   conversation"* — it would make the agent keep working after it had finished. Use
   `SessionStart` + `UserPromptSubmit`.

### 1.6 The Codex live probe (run during Phase 2)

Two `codex exec` runs, Codex CLI 0.147.0, an ephemeral read-only session in a scratch
workspace with the hook supplied through `-c` overrides rather than an installed plugin, so
nothing in JT's real Codex config was touched. Each hook printed a distinct nonce and the
prompt asked for it, with `NOTOKEN` as the negative answer.

| Hook output shape | Result |
|---|---|
| `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…ZEBRA-7741-QUAIL…"},"suppressOutput":true}` | model answered `ZEBRA-7741-QUAIL` |
| plain text: `SYSTEM NOTE: … OTTER-3312-MANGO …` | model answered `OTTER-3312-MANGO` |

**Both channels inject.** The JSON shape this hook emits works on Codex exactly as it does
on Claude Code — that part of the plan is confirmed. But plain stdout injects too, which
contradicts what §1's original reasoning inferred from the schema. Each run returned only
its own nonce, and Codex echoed neither, so this is delivery to the model rather than
terminal bleed.

Codex surfaced both identically in the transcript (`hook: UserPromptSubmit` →
`hook: UserPromptSubmit Completed`), with no warning about the non-JSON output.

### Five bugs and gaps found while probing

These are in scope for this change-set except where marked.

1. **The existing preflight reports JT's working key as rejected.** `agentmail-preflight.sh`
   with no flag probes `organizations get`. On JT's inbox-scoped key that returns
   `403 missing_permission` with the `fix` *"Organization details require an
   organization-scoped credential; this permission cannot be granted to an inbox- or
   pod-scoped API key"* — and the script classifies 401/403 as **exit 12, CREDENTIAL
   REJECTED**. The key is fine. Fix in §5.
2. **`count` is the number of items returned, not the number matching.**
   `--label unread --limit 1 --transform count` → `1`; `--limit 5` → `3` (the true total).
   A naive unread counter built on a small `--limit` always reports that limit. The hook
   must over-request and render `N+` at the ceiling.
3. **Search takes `-q`, not `--query`.** `--query` fails with
   `flag provided but not defined: -query`. Neither `SKILL.md` nor the docs say so.
4. **CLI 0.7.14 does not expose `auth me`.** `openapi.json` documents `/v0/auth/me` with a
   literal `**CLI:** agentmail auth me` block, but there is no `auth` resource in
   `--help`. Not needed — `inboxes list` succeeds on an inbox-scoped key and yields the
   inbox id — but worth recording so nobody plans around it.
5. ~~**Out of scope, needs its own issue:** `plugins/handoff/hooks/scripts/session-start.sh`
   injects context by printing plain text, which probably never reaches the model under
   Codex.~~ **WITHDRAWN — this was wrong.** The live probe in §1.6 shows plain stdout does
   reach the model under Codex. `handoff` works. The claim came from reading
   `additionalProperties: false` in Codex's hook *output* schema as a statement about what
   Codex does with output that isn't JSON, which it is not. beads claude-plugins-koht is
   closed as not-a-bug with the probe recorded on it.

---

## 2. File tree

`+` new, `~` edited, `→` moved.

```
plugins/agentmail/
├── .claude-plugin/plugin.json                          (unchanged, stays 0.1.0)
├── README.md                                         ~ new skills, hook setup, harness gaps
├── hooks/
│   ├── hooks.json                                    + SessionStart + UserPromptSubmit
│   └── scripts/mail-check.sh                         + the whole hook, one script, both harnesses
├── scripts/                                          + plugin-root shared (AGENTS.md § sharing)
│   ├── agentmail-preflight.sh                        → moved from skills/using-agentmail/scripts/
│   ├── agentmail-contacts.sh                         + contacts store CRUD
│   └── agentmail-inbox.sh                            + resolve + cache the inbox id
├── references/                                       + plugin-root shared
│   ├── replying.md                                   + reply/reply-all/forward/draft mechanics
│   ├── agent-mail-protocol.md                        + the [HANDOFF]/[ASK]/[FYI]/[DONE] contract
│   ├── mail-check.example.json                       + config template, placeholder addresses
│   └── (no contacts.example.json — see §3)
├── skills/
│   ├── using-agentmail/
│   │   ├── SKILL.md                                  ~ preflight path, -q, count semantics, pointers
│   │   ├── agents/openai.yaml                          (unchanged)
│   │   ├── references/{onboarding,recipes}.md         ~ preflight path only
│   │   └── scripts/{agentmail-signup,agentmail-verify}.sh  ~ nothing; preflight leaves
│   ├── contacts/{SKILL.md, agents/openai.yaml}       + address book
│   ├── check-mail/{SKILL.md, agents/openai.yaml}     + list unread/recent, read bodies, triage
│   ├── replying/{SKILL.md, agents/openai.yaml}       + reply / reply-all / forward, draft-first
│   └── relay-work-order/{SKILL.md, agents/openai.yaml} + agent-to-agent work orders
└── tests/
    ├── skill-contract_test.sh                        ~ loop all 5 skills; validate hooks.json
    ├── safety_test.sh                                ~ new skills; hook secret + exit hygiene
    ├── preflight_test.sh                             ~ missing_permission reclassification
    ├── contacts_test.sh                              + store behavior
    └── mail-check_test.sh                            + hook behavior vs. a stubbed CLI
```

### Why `agentmail-preflight.sh` moves to the plugin root

It gains four consumers: `using-agentmail`, `check-mail`, `replying`, `relay-work-order`,
plus the hook. AGENTS.md is explicit — *"two or more skills in one plugin need the same
script, keep one copy at the plugin root"* — and names this repo's two prior transcript-parser
duplications as the reason. `${CLAUDE_SKILL_DIR}/../../` is unsupported, so a shared script
cannot be reached from a skill subdirectory any other way. `signup` and `verify` stay under
`using-agentmail/scripts/` because only that skill uses them.

The hook reaches it as `${CLAUDE_PLUGIN_ROOT}/scripts/agentmail-preflight.sh --local`,
discards stdout, and branches on the exit code — the exit-code contract is already the
documented interface, which is exactly why the hook can reuse it silently.

The existing `allowed-tools` matcher `Bash(bash */scripts/agentmail-preflight.sh*)` still
matches after the move. `README.md` and both reference docs name the old path and get updated.

### Four new skills, not five — the merge and the split, justified

The work order names five. Recommendation is **four**, differing in one place.

**Merge `checking mail` + `triage` into `check-mail`.** Their trigger phrases are the same
sentences — "any new mail?", "what's in the inbox?", "anything I need to deal with?" — so as
two skills they compete for the same routing and one wins arbitrarily. Worse, whichever
wins is incomplete: a model that loads a bare "list unread" skill lacks the classification
vocabulary and the tag protocol it needs the moment it reads what it just listed. Triage is
not a second task, it is what you do with the output of the first one.

**Keep `replying` and `relay-work-order` separate.** Distinct triggers ("reply to that" vs.
"send ChatGPT a handoff"), distinct risk profiles (one is correspondence, one is a contract
with another autonomous agent that has hard guardrails), and the relay protocol needs to be
findable by name because a counterpart skill on the ChatGPT side already refers to it.
Burying it inside a reply skill hides the one piece with teeth.

Their shared body — reply vs. reply-all headcount, in-thread threading, draft-first — lives
once at `references/replying.md` and is cited by both, plus `check-mail`. Cross-skill
references are unsupported, so plugin root is the only correct home.

`contacts` is its own skill: no API surface, no send gate, no key required, and a completely
separate trigger vocabulary ("what's X's email?").

Invocation: `/agentmail:contacts`, `/agentmail:check-mail`, `/agentmail:replying`,
`/agentmail:relay-work-order` in Claude Code; `$agentmail:…` in Codex.

---

## 3. Contacts

### Store

`${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/contacts.json`, mode `0600`.

Beside the existing `state.json` the plugin already writes there, so there is one AgentMail
config directory rather than two. **Never in the repo** — it holds personal addresses, and
anything under a git worktree is one `git add -A` from being published. The path is derived
from the environment only; there is no `--store` flag for a model to point somewhere else
(the tests redirect `HOME`/`XDG_CONFIG_HOME`, as the existing suites already do).

```json
{
  "version": 1,
  "contacts": [
    {
      "id": "jt",
      "name": "JT (Justin Sternberg)",
      "email": "me@jtsternberg.com",
      "kind": "human",
      "role": "human owner",
      "notes": "Final approver for anything outward-facing.",
      "aliases": ["Justin", "owner"],
      "added_at": "2026-08-11T22:00:00Z",
      "verified_from": "received mail 2026-08-11T20:29:42Z"
    }
  ]
}
```

Single JSON file, not JSONL: the set is small, edits are rare and interactive, and a human
opening it in an editor is a first-class use. `id` is a slug, generated from `name` when not
given, and is the stable handle for `update`/`remove`. `kind` is `human` | `agent` and is
load-bearing rather than decorative — the relay protocol applies to `agent` contacts, and
the "route it through the human" guardrail resolves to the `human` ones.
`verified_from` exists because of the `<partner-alt>` lesson: every address records how it was
confirmed, so the next agent can tell evidence from recollection.

Writes are temp-file-plus-`mv` in the same directory. Concurrent sessions are last-writer-
wins; the cost of losing a race is one re-added contact, and locking is not worth the
failure modes.

### `scripts/agentmail-contacts.sh`

```
agentmail-contacts.sh init                       # create an empty 0600 store; never overwrites
agentmail-contacts.sh list   [--format json|text]
agentmail-contacts.sh get    <query> [--format json|text]
agentmail-contacts.sh add    --name N --email E [--kind human|agent] [--role R]
                             [--notes T] [--alias A]... [--verified-from V]
agentmail-contacts.sh update <id-or-query> [same flags]
agentmail-contacts.sh remove <id-or-query> --yes
```

`get` matches case-insensitively against `id`, `name`, `aliases`, and `email`, exact before
substring. Exit codes are the interface, as elsewhere in this plugin:

`0` ok · `3` no match · `4` conflict (an email already present, or an ambiguous query
matching several contacts — it prints the candidates and changes nothing) · `5` store
present but malformed (never silently rewritten) · `64` usage.

`remove` requires `--yes` so a bare invocation cannot delete.

### Seed

Created by the `contacts` skill on first use, from live evidence, **not shipped in the repo**:

| name | email | kind | verified_from |
|---|---|---|---|
| JT (Justin Sternberg) | me@jtsternberg.com | human | received mail 2026-08-11T20:29:42Z |
| JT's ChatGPT | <partner-agent>@agentmail.to | agent | thread 019def1e…, 4 messages, 2026-08-11 |
| This agent (self) | <claude-inbox>@agentmail.to | agent | `inboxes list`, `count: 1` |

The ChatGPT contact carries an `aliases` entry for its original inbox and
`notes: "<partner-alt> is this agent's original inbox (JT, verbally, session bd2a8174);
<partner-agent> came later and is the one on the wire. Unconfirmed from any message in this
inbox, and an inbox-scoped key cannot enumerate others — do not send to it until JT
confirms."` The `verified_from` on that alternate reads `JT verbal, not observed`, which is
the distinction the field exists to carry.

**Built without the planned `references/contacts.example.json`.** A template file is
something the model can copy verbatim, and a placeholder contact copied into a real store is
worse than an empty one — it looks like data. The skill's first-run section instructs seeding
from *observed* senders instead (read the inbox, use the message or thread as
`verified_from`), which is the behavior the template was only gesturing at. `safety_test.sh`
still enforces the no-live-address rule on everything that does ship.

---

## 4. Mail-check hook

### Config

`${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/mail-check.json`
(override `AGENTMAIL_MAIL_CHECK_CONFIG` — for tests and unusual setups).

```json
{
  "version": 1,
  "enabled": true,
  "mode": "remind",
  "inboxes": ["<claude-inbox>@agentmail.to"],
  "check_every_minutes": 15,
  "session_start_floor_seconds": 60,
  "renotify_after_minutes": 120,
  "max_messages": 3,
  "per_message_bytes": 400,
  "max_bytes": 2000,
  "list_ceiling": 25,
  "timeout_seconds": 8
}
```

| field | default | meaning |
|---|---|---|
| `enabled` | `true` *when a config file exists* | master switch |
| `mode` | `"remind"` | `remind` \| `auto` \| `off` |
| `inboxes` | resolved + cached | omit to let the hook derive it from `inboxes list` |
| `check_every_minutes` | `15` | cooldown before another API call on `UserPromptSubmit` |
| `session_start_floor_seconds` | `60` | `SessionStart` bypasses the cooldown down to this floor, so a fresh session isn't silenced by another session's recent check |
| `renotify_after_minutes` | `120` | with the same newest unread message, stay quiet this long |
| `max_messages` | `3` | `auto` mode: hard cap on summaries |
| `per_message_bytes` | `400` | `auto` mode: per-preview truncation |
| `max_bytes` | `2000` | `auto` mode: hard cap on the whole injected string |
| `list_ceiling` | `25` | `--limit` for the unread query; at the ceiling the notice says `25+` (finding §1.2) |
| `timeout_seconds` | `8` | internal watchdog, under the hook's own `timeout: 10` |

**No config file → the hook is a no-op.** A hook that makes a network call before every
prompt must not switch itself on at install time; activation is an explicit act. Once a
config exists, `remind` is the default mode and `auto` is opt-in, as specified.

### Activation is one gesture, not hand-written JSON

```
mail-check.sh --init [--mode remind|auto] [--inbox <id>]
```

Copies `references/mail-check.example.json` into place, substituting `mode` and — when
`--inbox` is omitted — leaving `inboxes` unset so the hook resolves and caches it on first
run. It **never overwrites** an existing config (exit `4`, prints the existing path so the
user can edit or delete it deliberately), and on success it prints exactly what it wrote and
where, so activation is legible rather than magic.

"Default-off" must not mean "off unless you can hand-author JSON" — an opt-in whose only
door is an undocumented file shape is off in practice. `--init` is the door. It is named in
`README.md` and in `check-mail`'s onboarding section, and it is the only write path the
skills offer for this file.

### State

`${XDG_CACHE_HOME:-$HOME/.cache}/agentmail/mail-check-state.json`, mode `0600`. Cache, not
config: deleting it costs one extra API call and nothing else.

```json
{
  "version": 1,
  "inboxes": {
    "<claude-inbox>@agentmail.to": {
      "last_checked_at": 1786000000,
      "last_notified_at": 1785990000,
      "unread_count": 3,
      "at_ceiling": false,
      "newest_message_id": "<0100019ff2b3ad74-…@email.amazonses.com>"
    }
  }
}
```

Keyed per inbox, shared across sessions. `newest_message_id` is what makes the notice stop
nagging: re-notify only when the newest unread changes, or after
`renotify_after_minutes`. Time alone would repeat "3 unread" every 15 minutes forever while
JT deliberately ignores them, which trains everyone to ignore the notice.

### Flow

```
SessionStart (startup|resume)          UserPromptSubmit (no matcher)
        └────────────────┬───────────────────────┘
                         ▼
        mail-check.sh --event <SessionStart|UserPromptSubmit>
                         │
   config missing ───────┼────────────────────────────────► exit 0, silent
   enabled:false / mode:"off" ───────────────────────────► exit 0, silent
   no python3 and no jq (cannot build safe JSON) ────────► exit 0, silent
   preflight --local != 20  (no CLI, or no key) ─────────► exit 0, silent
   within cooldown ─────────────────────────────────────► exit 0, silent
        │   UserPromptSubmit: now - last_checked_at < check_every_minutes
        │   SessionStart:     now - last_checked_at < session_start_floor_seconds
                         ▼
        resolve inbox: config.inboxes → state cache → `inboxes list`
   unresolvable ────────────────────────────────────────► exit 0, silent
                         ▼
        agentmail inboxes:messages list --inbox-id <id> \
          --label unread --limit <list_ceiling> --format json
   non-zero / timeout / unparseable ──► write last_checked_at, exit 0, silent
                         ▼
        write state (last_checked_at, unread_count, at_ceiling, newest_message_id)
                         │
   unread_count == 0 ───────────────────────────────────► exit 0, silent
   newest_message_id unchanged AND
     now - last_notified_at < renotify_after_minutes ───► exit 0, silent
                         ▼
        mode remind → one line
        mode auto   → one line + up to max_messages summaries,
                      each ≤ per_message_bytes, whole string ≤ max_bytes
                         ▼
        write last_notified_at
        print ONE JSON object, exit 0
```

Every branch exits 0. The only thing ever written to stdout is that object:

```json
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…"},"suppressOutput":true}
```

`hookEventName` must match the firing event, so it comes from the `--event` argv value that
`hooks.json` supplies — deterministic, and no stdin parse needed on the hot path. An
unrecognized `--event` exits 0 silently rather than emitting a mismatched object.

### What it injects

`remind` (default):

```
AgentMail: 3 unread in <claude-inbox>@agentmail.to as of 21:34 — newest
"Re: Hello from Claude" from <partner-agent>@agentmail.to. Ask me to check it.
```

`auto` (opt-in):

```
AgentMail: 3 unread in <claude-inbox>@agentmail.to as of 21:34.
1. Re: Hello from Claude — JT's ChatGPT <<partner-agent>@agentmail.to>, 21:21
   Hey Claude — Your proposed approach is now codified on my side as the …
2. Re: Claude's inbox is live — Justin Sternberg <me@jtsternberg.com>, 20:29
   …
Previews are truncated and unread state is unchanged; read full bodies before acting.
```

The `as of HH:MM` stamp is not decoration. Claude Code **replays saved injected text** on
`--resume` rather than re-running the hook for past turns, so a stale "3 unread" line will
reappear in a resumed session; the timestamp is what makes that legible instead of
misleading.

`auto` mode costs the same single API call as `remind`: `inboxes:messages list` already
returns `from`, `subject`, `timestamp`, and `preview`, so no `get` calls are needed. That
also means `auto` shows previews, never full bodies — hence the closing sentence, which
points at `check-mail` for the real thing.

The invocation hint is harness-aware, following `handoff`'s precedent: `CLAUDE_CODE_SESSION_ID`
→ `/agentmail:check-mail`, `CODEX_THREAD_ID` → `$agentmail:check-mail`, both-or-neither →
harness-neutral wording. Naming the wrong client's syntax is worse than naming none.

### `hooks/hooks.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "shell": "bash",
            "timeout": 10,
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/mail-check.sh\" --event SessionStart || true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "shell": "bash",
            "timeout": 10,
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/mail-check.sh\" --event UserPromptSubmit || true"
          }
        ]
      }
    ]
  }
}
```

No `matcher` on `UserPromptSubmit` — Claude Code documents that event as having no matcher
support. `timeout: 10` sits under Claude Code's 30-second `UserPromptSubmit` default and is
honored by Codex; a timeout on either harness discards the output and lets the prompt
through, which is the correct degradation. `|| true` and the script's unconditional `exit 0`
are belt and braces.

### Safety properties, each one asserted in `mail-check_test.sh`

- The script never reads, prints, or interpolates `AGENTMAIL_API_KEY`. The CLI picks it up
  from the environment itself; the hook only checks *whether* it is set, via preflight's
  exit code.
- No branch can exit non-zero, so no configuration can fail a session.
- It performs **read-only** calls. It never marks anything read, never labels, never drafts.
  Marking read after triage is a real workflow, but it is a mutation and stays behind a
  permission prompt in `check-mail`, not in a hook that runs unattended.
- It writes only under `$HOME` (config dir, cache dir). Nothing in the repo, nothing in `/tmp`.
- The injected string is built with `python3` (fallback `jq`) — never `printf` — because
  previews contain quotes, newlines, and non-ASCII, and a hand-built JSON string would break
  the harness's parse on the first apostrophe. With neither tool available, the hook is silent.
- Truncation is UTF-8-boundary-safe.

### Codex: what works, what degrades

Achievable, specified above, and now **live-verified** (§1.6): the same `hooks.json`, the
same script, the same two events, the same JSON object, and the model reads it. No degraded
mode is needed — the `SessionStart`-only fallback this spec held in reserve is not required
and was not built.

Two honest gaps, both going into `README.md`:

1. **Trust gate.** Codex will not run plugin hooks until the user trusts them, so the first
   Codex session after install is silent by design. Documented as a setup step, never
   bypassed. (The §1.6 probe used `--dangerously-bypass-hook-trust` precisely because the
   gate is real.)
2. **No `Stop`-time nudge on either harness**, for the reason in §1: `Stop`'s
   `additionalContext` continues the conversation.

---

## 5. Edits to existing files

**`scripts/agentmail-preflight.sh`** (after the move):

- Probe `inboxes list` instead of `organizations get`. It succeeds on inbox-, pod-, and
  org-scoped keys; `organizations get` succeeds only on org-scoped ones, which is what
  produced finding §1.1.
- Reclassify `missing_permission`: a key that is *recognized but scope-limited* is a working
  key. It now exits **0** with a "key accepted, scope-limited — `fix` says: …" note. Exit
  **12** narrows to genuine rejection: a 401/403 with no `code`, or
  `unknown_api_key`/`unauthorized`/`missing_authorization`/`invalid_token_type`.
- Print the resolved inbox id on success. Every other skill and the hook need it, and it
  arrives free in the probe response.
- Exit codes `10`/`11`/`20`/`30`/`64` are unchanged.

**`skills/using-agentmail/SKILL.md`**: preflight path → `${CLAUDE_PLUGIN_ROOT}/scripts/`;
`organizations get` is no longer the auth probe (say why); search takes `-q`; `count` is the
returned count, not the total; `auth me` is documented but absent from CLI 0.7.14; pointers
to the four new skills and the two shared references.

**`skills/using-agentmail/references/{onboarding,recipes}.md`**: preflight path only.

**`README.md`**: the new skills and the split rationale; hook install/activation for both
harnesses including the Codex trust gate; the contacts store location and that it is never
committed; the harness gap table.

---

## 6. Test plan

TDD: every suite below is written and failing before the code it covers. All five run under
`bash tests/run-all.sh` by glob (`plugins/<plugin>/tests/<name>_test.sh`), no runner edit.
Nothing touches the real API or a real key: `agentmail` is stubbed on `PATH` and
`HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` are redirected into a temp dir, following the
existing `preflight_test.sh` convention.

Gate for every commit:

```bash
for t in skill-contract safety preflight contacts mail-check; do
  bash plugins/agentmail/tests/${t}_test.sh
done
bash tests/run-all.sh
```

### `contacts_test.sh` (new)

`init` creates a `0600` store and refuses to overwrite · `add` then `get` round-trips ·
`get` matches by id, name, alias, and email, case-insensitively, exact before substring ·
ambiguous `get` exits 4, lists candidates, changes nothing · duplicate email exits 4 ·
`update` merges without dropping unset fields · `remove` without `--yes` is refused and the
store is unchanged · `remove --yes` deletes · missing store yields an empty list, exit 0, no
crash · malformed store exits 5 and is **not** rewritten · the store is written atomically
(no partial file after an interrupted write) · store lands under the redirected `HOME`, never
in the repo · output is valid JSON under `--format json`.

### `mail-check_test.sh` (new)

Silent-and-zero: no config · `enabled:false` · `mode:"off"` · no CLI on `PATH` · no key ·
stub returning 403 · stub returning malformed JSON · stub hanging past `timeout_seconds` ·
unknown `--event`. Each asserts empty stdout **and** exit 0.

Behavior: `remind` emits exactly one JSON object whose `hookSpecificOutput.hookEventName`
equals the `--event` value and whose `additionalContext` names the count and the inbox ·
`auto` respects `max_messages`, `per_message_bytes`, and `max_bytes` · `auto` output is
truncated at a UTF-8 boundary for a multibyte preview · a stub returning `count == list_ceiling`
renders `25+` (the finding §1.2 regression guard) · zero unread is silent · a second run
inside `check_every_minutes` is silent **and makes no CLI call** (asserted via the stub's
log, the same technique `preflight_test.sh` uses to prove `--local` is offline) ·
`SessionStart` bypasses the cooldown but honors `session_start_floor_seconds` · an unchanged
`newest_message_id` inside `renotify_after_minutes` is silent · a changed
`newest_message_id` re-notifies immediately · state is written even on a failed probe, so a
broken key cannot cause a call per prompt · `CLAUDE_CODE_SESSION_ID` yields `/agentmail:`,
`CODEX_THREAD_ID` yields `$agentmail:`, both-or-neither yields neither form.

Secret hygiene: with the stub key set to a labelled fake, that literal appears nowhere in
stdout, in the state file, or in the config file.

### `skill-contract_test.sh` (extended)

The existing single-skill assertions become a loop over all five skills: discoverable
`skills/<name>/SKILL.md`; frontmatter `name` matching the directory; `description`,
`when_to_use`, `argument-hint`, `allowed-tools` present; Codex routing terms in
`description` (Codex ignores `when_to_use`); `agents/openai.yaml` present; bare
`${CLAUDE_SKILL_DIR}` / `${CLAUDE_PLUGIN_ROOT}` tokens with no shell-default wrapper; a
Codex substitution sentence adjacent to every path token; the local assignment repeated in
every independently executed block; **no `${CLAUDE_SKILL_DIR}/../`**; no bare relative
reference path in prose.

New: `hooks/hooks.json` parses; every event name is in the Claude Code ∩ Codex supported
set; every command is anchored at `${CLAUDE_PLUGIN_ROOT}`; every entry sets a `timeout`;
`UserPromptSubmit` carries no `matcher`.

### `safety_test.sh` (extended)

The send/delete allowlist ban extends to all five skills — `replying` and `relay-work-order`
must allowlist only read verbs, so `reply`, `reply-all`, `forward`, and `drafts send` keep
prompting. `relay-work-order`'s SKILL.md must contain the destructive-action guardrail and
the ambiguous-handoff→`[ASK]` rule (prose is advisory, a test is not). Every file under
`hooks/` and `scripts/`: no `echo`/`printf` of a key-shaped variable, and no path that can
exit non-zero from `mail-check.sh`.

New: **no live `@agentmail.to` address in any shipped plugin file.** Implemented as an
allowlist of example local-parts (`my-agent`, `partner-agent`, `abc123`, `support`, `you`,
`agent`) rather than a denylist of JT's real inbox names — a denylist would have to name the
live addresses in order to ban them, which is the leak it exists to prevent.

### `preflight_test.sh` (extended)

New stub modes: a `403 missing_permission` response now exits **0** and says "scope-limited"
(the §1.1 regression guard) · the probe calls `inboxes list`, asserted via the stub log ·
the resolved inbox id is printed on success. Existing cases — bare
`{"message":"Forbidden"}` → 12, 429 → 30, `--local` makes no call → 20 — must still pass
unchanged.

### Manual probes before Phase 2 is called done

1. Claude Code: activate the hook, confirm the notice appears, confirm silence on the second
   prompt inside the cooldown, confirm the debug log shows the injected context.
2. Codex: the live `additionalContext` probe from §4, recorded in
   `docs/codex/hooks-under-codex.md`.
3. `validate-dual-harness-skill` against all five skills.

No probe sends mail or mutates inbox state.

---

## 7. Decisions (reviewed and approved 2026-08-11)

All six open questions are resolved. Recorded as decisions rather than deleted, so the
reasoning survives for whoever reads this next.

| | Question | Verdict |
|---|---|---|
| Q1 | Publish the live agent addresses in this spec? | **Redact.** Placeholders throughout; real values live only in the local store. The §1 evidence is message counts and thread structure, which survives redaction. `safety_test.sh` keeps the shipped-file ban. |
| Q2 | Treat `<partner-alt>` as real? | **Unverified note, enriched provenance.** JT confirmed verbally (session bd2a8174) that it is ChatGPT's original inbox and `<partner-agent>` came later. Recorded as JT-verbal, not observed; never send to it without confirmation. |
| Q3 | Four skills or five? | **Four.** The work order listed functions, not a skill count; the routing-collision argument for merging `checking mail` into `check-mail` stands. |
| Q4 | Move the preflight to the plugin root now? | **Now** — before more consumers ship against the wrong path. |
| Q5 | Change the preflight exit-code contract at `0.1.0`? | **Yes, now.** Version stays `0.1.0` through testing per JT's hold. The release bump (likely `0.2.0`) must call the exit-code change out in `README.md` and the release notes — tracked so it cannot ship silently. |
| Q6 | Hook default-off? | **Default-off, plus a one-gesture `--init`.** An opt-in whose only door is hand-written JSON is off in practice. See §4. |

## 8. Tracking

Epic **claude-plugins-nd5f**, with one issue per build unit:

| id | |
|---|---|
| claude-plugins-otxr | preflight reports a working inbox-scoped key as REJECTED (§1.1, §5) |
| claude-plugins-736x | contacts store + `contacts` skill (§3) |
| claude-plugins-k8fe | mail-check hook, both harnesses (§4) |
| claude-plugins-fdbk | `check-mail`, `replying`, `relay-work-order` + shared references (§2) |
| claude-plugins-0t05 | live-probe Codex `additionalContext` delivery (§4, gap 2) |
| claude-plugins-hyuk | release bump must document the preflight exit-code change (§7 Q5) |
| claude-plugins-koht | **out of scope:** `handoff`'s plain-stdout hook under Codex (§1.5) |
