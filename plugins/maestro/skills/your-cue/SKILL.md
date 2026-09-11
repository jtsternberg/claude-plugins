---
name: your-cue
description: >
  Read-only briefing across every live agent session — which agents are
  working, which are waiting on the user, what finished while they were away —
  ending in one concrete cue per workstream and a single prioritized
  "Next for you:". Use when the user asks what their agents are doing, what
  needs them, what happened overnight, or wants a morning briefing, a catch-up
  across workspaces, or a status sweep of delegated work.
---

# Your Cue — tell the human what each workstream needs from them

Catch-up is the input; the cue is the product. A list of running agents is not
a briefing. Every workstream leaves this skill with a verb the human can act
on, or an explicit "nothing" and the reason.

Takes no arguments. Invoked as `/maestro:your-cue` (Codex:
`$maestro:your-cue`), it sweeps whatever is reachable and briefs.

## Rule zero — read only, start to finish

Discovery and inspection only: pane focus, seen state, notifications, and
session input all survive untouched. This run changes nothing, in either host.

Read-only and safe:

- **cmux** — `cmux tree --all --json`, `cmux sidebar-state`,
  `cmux list-notifications`,
  `cmux read-screen --surface <id> --scrollback --lines <n>`.
- **herdr** — `herdr agent list`, `herdr agent get|read`,
  `herdr workspace list|get`, `herdr tab list|get`, `herdr pane list|get|read`.
- **graveyard** — `graveyard candidates --json`.

Never run, even to "just check":

- **cmux** `focus-pane` (moves the human's focus, so their next keystrokes go
  into the pane), `send-key` (lands in a live REPL and can destroy an in-flight
  tool call), `clear-notifications` and `clear-history` (both destroy state the
  briefing is reporting on).
- **herdr** `prompt` and `send-keys` (submit input to the agent), `focus`
  (steals focus), `rename`, `start`, `attach`, and every `pane`/`tab`/
  `workspace` verb outside the read list above.
- **graveyard** `bury` — burial is a *cue* in this briefing, never an action.

`herdr agent read` with `--source recent` is the enrich read; bare
`cmux read-screen` without `--scrollback` returns the human's scrolled
viewport, not the live bottom, so always pass `--scrollback`.

## 1. Check reachability

`graveyard candidates --json` is the fast path when `graveyard` is installed:
one unified cmux + herdr inventory, and it works from outside both hosts.
Without it, take the portable path — `herdr agent list` plus
`cmux tree --all --json` and `cmux sidebar-state`.

**Probe each host yourself, even on the fast path.** One cheap read per
transport — `herdr agent list`, `cmux tree --all --json` — is the only honest
reachability signal. Graveyard does not report a host being down: with the
`herdr` CLI unavailable it exits 0, writes nothing to stderr, and relabels
every herdr row's `transport` as `cmux`. A row count that looks complete is
not evidence both hosts answered, and `transport` is not a reachability field.

**Stop and ask before briefing partial coverage.** When only one transport
answers, ask whether the human wants the one-host briefing now or wants to
resume when both are reachable — do not silently brief half the fleet as if it
were the fleet. When neither answers, offer a transcript-only briefing and wait
for a yes. A partial run that the human approved gets a `Coverage` section
naming what was unreachable.

## 2. Inventory the live agents

Graveyard rows carry `session_id`, `agent`, `transport`, `idle_seconds`,
`busy`, `buryable`, `targetable`, `reason`, `workspace_title`, `tab_title`,
`cwd` — usually enough on their own. Enrich only where a row is missing a
visible name or a status you need:

- `herdr agent list` adds `name` (the herdr agent/tab handle),
  `agent_status`, and `terminal_title_stripped` (the tab label). It does *not*
  carry a workspace title — resolve that with `herdr workspace get
  <workspace_id>`, one extra read, or from `herdr workspace list`. The title
  comes back as `result.workspace.label`, not `title`.
- `herdr agent get`/`read` key on the herdr `name`, not the Claude session
  UUID. Passing a session UUID returns `agent_not_found`.
- `cmux tree --all --json` and `cmux sidebar-state` supply surface titles,
  busy/idle pills, and unread notifications for cmux rows. The tree nests
  windows → workspaces (`title`) → panes → surfaces (`title`).
- `cmux list-notifications` names the unread notifications themselves, which is
  the cheapest `Waiting on you` signal a cmux row gives you.

**Native status outranks graveyard's `busy`.** Graveyard reports
`busy: false, buryable: true` for agents `herdr agent list` reports as
`working` — its idle clock and the host's lifecycle state are not the same
signal. When they disagree, the host wins: the row goes under
`Working`, and it gets no burial cue.

Terminal reads are the expensive, intrusive-feeling step: shortlist first, then
`cmux read-screen --surface <id> --scrollback --lines <n>` (or
`herdr agent read`) only for the rows whose state is still unclear.

Every item the human sees uses a locator they can find on screen:

- herdr: `<agent name>` in `<tab name>`, `<workspace name>`.
- cmux: `<surface title>` in `<workspace title>`; add a window anchor only when
  two workspaces share a title.

Session UUIDs and pane ids are internal lookup keys, not output. When no
visible name exists, say the agent is unnamed and include the smallest id that
locates it.

## 3. Nest the hotline callees

Read the call registry through `/hotline:hotline-call-status` (Codex:
`$hotline:hotline-call-status`). Each line gives `caller_session_id`,
`caller_path`, `target`, `callee_session_id`, `mode`, `last_contact`,
`host_handle`, and `transport`.

**Filter to the live inventory first.** The registry is append-only and nothing
prunes it, so the filter typically discards the overwhelming majority of rows —
skip it and the briefing is unreadable. Nest a callee only when its
`callee_session_id` or `host_handle` matches a session or handle in the
inventory from step 2, *and* its caller is in that inventory too. Every other
row is stale — ignore it silently, and never mention a caller or callee the
human cannot currently see.

A surviving callee renders nested beneath its caller, by visible name. A callee
that is itself a caller nests two deep — the chain is the point. Show a child
when it explains the parent's blocker or contradicts the parent's apparent
state; otherwise the caller's line is enough. A registry entry is a
record of a dial, not proof of life — the transports in step 2 are the
liveness authority.

## 4. Catch up only where needed

Native status plus a recent-output read answers most rows. When they don't —
the agent is idle mid-task and the screen doesn't say what task — get a bounded
transcript briefing from `/session-tools:sessions-catch-up <session-id>
--window 8` (Codex: `$session-tools:sessions-catch-up <session-id>
--window 8`).

`sessions-catch-up` is explicitly-invoked only, so you may not be able to route
to it yourself. When you can't, name that row in `Coverage` and cue the human to
run it — never pull the raw transcript into your own context as a substitute.

Two bounds, and only one of them is a flag:

- **Eight turns** — `--window 8` is real; pass it.
- **8,000 characters** — there is no character-limit flag anywhere in session
  tools. Enforce the ceiling yourself by truncating the digest with
  `head -c 8000` before any of it reaches the summarizing agent.

Hand the truncated digest to a cheaper model, not to your own context. Under
Claude Code, dispatch it to the Agent tool with `model: "haiku"` (or
`model: "sonnet"` when the transcript is tangled) and ask for three sentences:
what it was doing, where it stopped, what it needs. Under Codex, use its
subagent mechanism when one is available; with none, summarize inline from the
truncated digest — never read the full transcript into the main context.

**Stop after five summaries.** List the remainder — every still-unclear
workstream — by its visible locator with `Your cue: clarify`. An exhaustive
briefing that arrives late has failed at the one thing it was for.

## 5. Render the briefing

One workstream is one caller session plus its nested live callees — a callee
gets its own line only when step 3 says to show it — and a plot is a workspace
holding one or more workstreams. One cue per workstream, never one cue spanning
two unrelated sessions.

Render only the sections that have content. Every workstream ends with
`Your cue:` — a concrete verb (answer, approve, review, resume, clarify, close,
bury) when the human has a move, or `Your cue: nothing — <reason>` when the
agent is still working or the result is settled. "Nothing needed" is a
conclusion you state, not a line you omit.

```text
## Your cue

Waiting on you
- <visible agent locator> — <current status>. Your cue: <specific action>.

Working
- <visible agent locator> — <current task>. Your cue: nothing — it is still working.

Finished while you were away
- <visible agent locator> — <outcome and verification caveat>. Your cue: <review, close,
  continue, bury this session/plot, or nothing with reason>.

Coverage
- <only when cmux or Herdr was unavailable>

Next for you: <the highest-priority non-nothing cue and visible locator, or "nothing" when
every workstream's cue is nothing>.
```

`Next for you:` is one line, one action, never a menu — the single
highest-priority non-nothing cue, carrying its visible locator so the human
knows where to go. `Next for you: nothing` when every workstream is working or
settled; say it rather than trailing off.

### Burial cues

`Your cue: bury this session` requires both halves: the transcript shows the
work finished with no substantive follow-up left, **and** graveyard reports
`buryable: true` for that `session_id`. One half alone is not a burial cue.

**Unverified is not failed.** Step 4 caps transcript reads at five, so for most
finished rows the transcript half was never checked. When completion is not
established from the transcript, render `Your cue: review and close` — or
`Your cue: nothing — <reason>` where that fits — never a burial cue. A burial
cue is only ever emitted after the transcript check actually happened.

`Your cue: bury this plot` requires every `targetable` session sharing that
`workspace_title` to be finished and `buryable`. One live sibling downgrades it
to a per-session cue.

Burial stays text in the briefing: this skill leaves execution to the human or
to a later explicit request, and never runs `graveyard bury` itself.

## Anti-patterns

| Anti-pattern | Instead |
|---|---|
| A list of running sessions | A cue per workstream |
| Silently briefing one host | Stop and ask, then add `Coverage` |
| Session UUIDs and pane ids in prose | Visible names the human can see |
| Reading full transcripts into your context | `--window 8`, `head -c 8000`, cheaper model |
| Nesting every registry row | Only callees present in the live inventory |
| Burying, focusing, or notifying anything | Read-only; burial is a cue |
| Ending with a menu | One `Next for you:` |
