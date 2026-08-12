# AgentMail expansion: contacts, mail-check hooks, four new skills

**Status:** spec, awaiting review. Nothing built yet.
**Branch:** `agentmail-expansion` (worktree `/Users/JT/Code/gittree-agentmail-expansion`)
**Plugin version:** stays `0.1.0` — bump deferred.

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

### The known-contact ambiguity is resolved: `jtbot-chatgpt@agentmail.to`

Read-only `inboxes:messages list` on `jtbot-claude@agentmail.to` returned 6 messages:

```
2026-08-11T21:21:29Z  JT's ChatGPT <jtbot-chatgpt@agentmail.to>  -> jtbot-claude  [received,unread]  Re: Hello from Claude
2026-08-11T20:42:11Z  JT's Claude Code <jtbot-claude@…>          -> jtbot-chatgpt [sent]            Re: Hello from Claude
2026-08-11T20:32:46Z  JT's ChatGPT <jtbot-chatgpt@agentmail.to>  -> jtbot-claude  [received,unread]  Re: Hello from Claude
2026-08-11T20:29:42Z  Justin Sternberg <me@jtsternberg.com>      -> jtbot-claude  [received,unread]  Re: Claude's inbox is live
2026-08-11T20:29:32Z  JT's Claude Code                           -> jtbot-chatgpt [sent]            Hello from Claude
2026-08-11T20:27:21Z  JT's Claude Code                           -> me@jtsternberg.com [sent]       Claude's inbox is live
```

`jtbot-chatgpt@agentmail.to` is verifiable — four messages, one live thread
(`019def1e-8402-47d2-b606-fdcef4019608`). `me@jtsternberg.com` is verifiable — it sent
mail in. `jtbot-99@agentmail.to` is **not** verifiable from here and must not be seeded as
fact: it appears in no message, and an inbox-scoped key cannot enumerate other inboxes
(`inboxes list` returns exactly one, `count: 1`). A `-q jtbot-99` full-text search returned
one hit, but reading that message's body shows the match came from tokenizing `jtbot`, not
from the string `jtbot-99`.

So the seed records `jtbot-99` as an unverified alternate note on the ChatGPT contact, with
its provenance ("JT's memory") stated, not as an address to use.

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
| stdout → context | yes on `SessionStart`/`UserPromptSubmit` only | **not relied on** — see below |
| `hookSpecificOutput.additionalContext` | yes | **yes** — same field, same casing |
| `${CLAUDE_PLUGIN_ROOT}` in a hook command | supported | supported |
| `timeout` | honored (UserPromptSubmit default drops to 30s) | honored |
| Runs on first install | yes | **no — trust gate** |

The decisive evidence for Codex is `codex-rs/hooks/schema/generated/`
`user-prompt-submit.command.output.schema.json` and `session-start.command.output.schema.json`
on `openai/codex@main`: both declare `hookSpecificOutput.additionalContext` (string) with
`additionalProperties: false`.

Two consequences drive the design:

1. **Always emit JSON, never plain text.** Claude Code accepts either; Codex's output
   schema is strict JSON, so plain stdout is not a context channel there. One JSON object
   is valid on both — that is the parity mechanism, and it is the whole reason this hook can
   be one script instead of two.
2. **`Stop` is the wrong event.** Claude Code does not add `Stop` stdout to context, and
   `Stop`'s `additionalContext` is explicitly *"non-error feedback that continues the
   conversation"* — it would make the agent keep working after it had finished. Use
   `SessionStart` + `UserPromptSubmit`.

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
5. **Out of scope, needs its own issue:** `plugins/handoff/hooks/scripts/session-start.sh`
   injects context by printing plain text. Given the Codex output schema above, that
   probably never reaches the model under Codex. `docs/codex/hooks-under-codex.md` proved
   the hook *executes*; it did not prove the text lands. Filed as a beads task, not fixed
   here.

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
│   └── contacts.example.json                         + store template, placeholder addresses
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
`verified_from` exists because of the `jtbot-99` lesson: every address records how it was
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
| JT's ChatGPT | jtbot-chatgpt@agentmail.to | agent | thread 019def1e…, 4 messages, 2026-08-11 |
| This agent (self) | jtbot-claude@agentmail.to | agent | `inboxes list`, `count: 1` |

The ChatGPT contact carries `notes: "JT's memory also mentions jtbot-99@agentmail.to. No
evidence of it in this inbox, and an inbox-scoped key cannot enumerate other inboxes —
confirm with JT before using it."`

`references/contacts.example.json` — the only contacts file that ships — uses
`you@example.com` / `partner-agent@agentmail.to`. Rationale in open question **Q1**.

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
  "inboxes": ["jtbot-claude@agentmail.to"],
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

### State

`${XDG_CACHE_HOME:-$HOME/.cache}/agentmail/mail-check-state.json`, mode `0600`. Cache, not
config: deleting it costs one extra API call and nothing else.

```json
{
  "version": 1,
  "inboxes": {
    "jtbot-claude@agentmail.to": {
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
AgentMail: 3 unread in jtbot-claude@agentmail.to as of 21:34 — newest
"Re: Hello from Claude" from jtbot-chatgpt@agentmail.to. Ask me to check it.
```

`auto` (opt-in):

```
AgentMail: 3 unread in jtbot-claude@agentmail.to as of 21:34.
1. Re: Hello from Claude — JT's ChatGPT <jtbot-chatgpt@agentmail.to>, 21:21
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

Achievable and specified above: the same `hooks.json`, the same script, the same two events,
the same JSON. That parity is a finding, not an assumption — `additionalContext` is in
Codex's generated output schema for both events.

Three honest gaps, all going into `README.md`:

1. **Trust gate.** Codex will not run plugin hooks until the user trusts them, so the first
   Codex session after install is silent by design. Documented as a setup step, never
   bypassed.
2. **Schema-verified, not yet live-probed.** The Codex evidence is `openai/codex@main`
   schemas plus this repo's prior `codex-cli` hook probe. Phase 2 must add a live probe —
   isolated `CODEX_HOME`, throwaway plugin, marker script, matching the methodology in
   `docs/codex/hooks-under-codex.md` — confirming `additionalContext` actually reaches the
   model on `UserPromptSubmit`, and record the result in that doc. If it does not, the
   degraded mode is `SessionStart`-only under Codex (start-of-session notice, no periodic
   check), config-gated so the difference is visible rather than mysterious.
3. **No `Stop`-time nudge on either harness**, for the reason in §1: `Stop`'s
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
exit non-zero from `mail-check.sh`. No live inbox address (`jtbot-claude@`, `jtbot-chatgpt@`)
in any shipped plugin file — the guard for the §3 seed decision.

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

## 7. Open questions

**Q1 — Publishing live agent addresses.** This spec records `jtbot-claude@agentmail.to` and
`jtbot-chatgpt@agentmail.to`, and it will be committed to a public repo. `me@jtsternberg.com`
is already in six files as your authorship email, so that one is settled; the two agent
inboxes are new exposure and are spammable. Plan: shipped plugin files use placeholders
(enforced by `safety_test.sh`), the real seed is created locally at runtime, and this spec
keeps the addresses because the whole point of §1 was resolving which one is real. Say the
word and I will redact them here to `jtbot-<agent>@agentmail.to` before the spec merges.

**Q2 — `jtbot-99@agentmail.to`.** Unverifiable from an inbox-scoped key. Seeded as an
unverified note on the ChatGPT contact. If you can confirm it from the AgentMail console,
it becomes a second verified contact; otherwise it stays a note. Either is fine — I just
won't assert it.

**Q3 — Four skills, not five.** The one deviation from the work order: `checking mail` and
`triage` merge into `check-mail` (§2). Confirm, or I ship five.

**Q4 — Moving `agentmail-preflight.sh` to the plugin root.** Correct per AGENTS.md and
needed by five consumers, but it touches `SKILL.md`, both reference docs, `README.md`, and
`preflight_test.sh` in one go. Confirm the churn is wanted now rather than deferred.

**Q5 — Preflight exit-code change.** `missing_permission` moves from exit 12 to exit 0.
That is a documented-interface change on a published `0.1.0` plugin, made without a version
bump (bump deferred per the work order). Flagging rather than assuming.

**Q6 — Hook default-off.** No config file means no-op, so installing the plugin changes
nothing until you write `mail-check.json`. Alternative is defaulting on in `remind` mode at
install, which means an unrequested network call before every prompt in every session in
every repo. Recommending default-off.

---

## 8. Tracking

Epic **claude-plugins-nd5f**, with one issue per build unit:

| id | |
|---|---|
| claude-plugins-otxr | preflight reports a working inbox-scoped key as REJECTED (§1.1, §5) |
| claude-plugins-736x | contacts store + `contacts` skill (§3) |
| claude-plugins-k8fe | mail-check hook, both harnesses (§4) |
| claude-plugins-fdbk | `check-mail`, `replying`, `relay-work-order` + shared references (§2) |
| claude-plugins-0t05 | live-probe Codex `additionalContext` delivery (§4, gap 2) |
| claude-plugins-koht | **out of scope:** `handoff`'s plain-stdout hook under Codex (§1.5) |
