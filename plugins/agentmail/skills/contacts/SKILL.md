---
name: contacts
description: "Address book for agent email — add, list, update, remove, and look up contacts (people and other agents) by name, alias, or address, so an AgentMail send goes to a verified address instead of a remembered one. Records how each email address was confirmed. Triggers on: what is X's email, who is X, add a contact, list contacts, update a contact, remove a contact, look up an address, which inbox does that agent use."
when_to_use: "Use when you need an email address you do not already have in front of you, or when the user wants to record, correct, or remove one — including another agent's inbox. Also use before any send whose recipient came from memory rather than from a message you just read: this store is what distinguishes a verified address from a recollected one. Not for reading or sending mail (that is check-mail, replying, and relay-work-order)."
argument-hint: "[who you're looking up, or the contact to add/change]"
allowed-tools:
  - "Bash(bash */scripts/agentmail-contacts.sh get*)"
  - "Bash(bash */scripts/agentmail-contacts.sh list*)"
  - "Read"
---

# Contacts

A local address book for agent mail: humans and other agents, with the address, the role,
and — the part that matters — how the address was **verified**.

## Why this is a local file

AgentMail has no contacts resource. Checked three ways: zero hits for `contact` across the
82 paths in `docs.agentmail.to/openapi.json`, no contacts page in the docs index, and no
`contacts` resource in CLI 0.7.14.

The nearest native thing is **Lists** (`lists`, `inboxes:lists`) — send/receive/reply ×
allow/block ACLs whose entries are an address-or-domain plus an optional `reason`. No name,
no role, no notes. And they are a security control: writing one changes what the inbox is
*allowed to talk to*, so a "remove a contact" gesture would silently alter deliverability.
Don't use them as an address book. If the user asks to *block* or *allow* a sender, that
genuinely is Lists — a different job, covered in `using-agentmail`.

## The store

`${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/contacts.json`, mode `0600`, beside the
`state.json` this plugin already writes.

**Never in the repository.** It holds personal addresses, and anything under a git worktree
is one `git add -A` from being published. The script derives its path from the environment
and takes no path flag, so there is nothing to point somewhere else by mistake.

## Running it

```bash
# Codex: substitute the installed plugin directory for this path.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/agentmail-contacts.sh" list
```

Repeat that assignment in every block you run — Codex shells keep no state between blocks.

```
init                        create an empty store; never overwrites
list   [--format json|text]
get    <query> [--format json|text]
add    --name N --email E [--kind human|agent] [--role R] [--notes T]
                          [--alias A]... [--verified-from V]
update <query> [any add flag]
remove <query> --yes
```

Exit codes, so you can branch without reading prose: `0` ok · `3` no match · `4` conflict
(duplicate address, ambiguous query, or `init` over an existing store — **nothing is
written**) · `5` store present but unparseable · `6` no python3 · `64` usage.

`get` matches `id`, `name`, `aliases`, and `email`, case-insensitively, **exact before
substring**. An ambiguous query prints the candidates and changes nothing rather than
picking one.

## Two fields that are not decoration

**`verified_from`** — how this address was confirmed. `received mail 2026-08-11T20:29:42Z`
and `thread 019def1e, 4 messages` are evidence. `the user mentioned it` and
`JT verbal, not observed` are not, and saying so is the point. This field exists because a
remembered address and an observed one look identical once they are both in a file, and the
consequence of confusing them is mail sent to an inbox nobody reads.

When you add a contact, say where the address came from. If you cannot, write what you
actually know — an honest `unverified: user said so in conversation` is worth more than a
blank.

**`kind`** — `human` or `agent`, defaulting to `unknown` rather than to `human`. It decides
two things: whether the `[HANDOFF]`/`[ASK]` protocol applies to a message (agents) and who
a destructive action routes through for approval (humans). A wrong guess there is worse
than a visible gap, so set it explicitly.

## First run

There is no seeded store. On first use, `init`, then add what you can **verify** — start
from the inbox rather than from memory:

```bash
# Codex: substitute the installed plugin directory for this path.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/agentmail-contacts.sh" init
```

Then read who has actually corresponded (`check-mail`, or
`agentmail inboxes:messages list --format json`) and add those senders with the message or
thread as `verified_from`. Add the agent's own inbox too — `agentmail inboxes list` names
it — because knowing your own address is what keeps you from emailing yourself.

Addresses the user only *told* you about go in with the provenance stated as such, or stay
out. Do not upgrade a recollection to a fact by writing it down confidently.

## Before a send

If a recipient address came from memory rather than from a message in front of you, look it
up here first. If it is not on file, or its `verified_from` says it was never observed, say
so to the user before sending rather than after.

`${CLAUDE_PLUGIN_ROOT}/references/agent-mail-protocol.md` covers what to do with an agent
contact once you have one. Codex: substitute the installed plugin directory for that path.
