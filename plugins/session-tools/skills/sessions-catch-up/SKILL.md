---
name: sessions-catch-up
description: "Distill another session's transcript into a briefing — status, blockers, what's waiting — without touching it."
when_to_use: |
  Use when the user wants to get back up to speed on a DIFFERENT session:
  "catch me up on <session-id>", "what was I doing in that session",
  "what's waiting on me in <id>", "summarize session <id>",
  "I stalled out on this a couple days ago, where did we land".
  Typically the target is a stalled session the user is returning to.
  Not for summarizing the CURRENT conversation, and not for git/branch
  catch-up (that is the unrelated /catchup command).
  If the user wants to BUILD on that session's work rather than just be
  briefed on it, use the companion `sessions-fork` skill instead.
disable-model-invocation: true
allowed-tools: "Bash(node *) Bash(bash *) Bash(bd *) Read Grep"
argument-hint: "<session-id|prefix|slug> [--deep] [--window N]"
---

# Sessions Catch-Up

Read another session's transcript off disk and brief the user on it. **Speed is the
product.** The user could scroll back and read the whole thing themselves — if this takes
as long or requires as much reading, it has failed.

So: **answer first, detail second.** Phase 1 is a short prose briefing, delivered
immediately. Phase 2 is optional and only happens if the user wants the longer arc.

> **Read-only with respect to the target session.** Never resume it, never
> `--fork-session` it, never send it input. Everything here comes off disk.
> `/export` is not usable: it is TUI-only (`claude -p "/export …"` answers
> *"/export isn't available in this environment"*), and driving it by typing into a live
> REPL would append a turn to the target.
>
> This constrains the *session*, not the repo. Doing new work informed by what you read is
> fine — if that's the goal, `sessions-fork` loads the context and hands back to the user.

## Arguments

Parse `$ARGUMENTS`:

- **first positional** — session id, id-prefix, slug, or title. Required.
- `--deep` — run Phase 2 without asking.
- `--window N` — turns kept near-verbatim (default 12).

If no target was given, list sessions and ask which one.

## Step 1 — Digest

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/export-session.mjs" "<target>" --format digest --fast
```

`node "${CLAUDE_PLUGIN_ROOT}/scripts/export-session.mjs" --list` lists every session
(id · idle · slug · cwd).

**Read `${CLAUDE_PLUGIN_ROOT}/references/reading-a-digest.md`** for how to resolve ambiguity, what each tail
state means, which signals to trust, and how to dig deeper. That file is shared with
`sessions-fork` so the two skills can never drift on it.

## Step 2 — Brief the user (this is the deliverable)

Lead with prose. **2–3 paragraphs**, plain language, answering: what was this session
doing, how far did it get, what is the state right now. Then the two short lists.

```
## <title or slug> — <cwd> (<branch>)
<liveness> · N turns · last activity <when>

<2–3 paragraphs of where it landed>

**⏳ Waiting on you**
- <open questions, pending approvals, unfinished todos, still-open beads>
- or: "Nothing explicit — it was mid-work on X."

**Suggested next step**
- <one concrete action>
```

Lead the first paragraph with the tail state — `BLOCKED ON YOU`,
`YOUR MESSAGE MAY BE UNANSWERED`, and `INTERRUPTED MID-TURN` each mean something
different. Keep it skimmable: no tool-by-tool narration. The user wants orientation, not
a replay.

## Step 3 — Offer the deep pass (only when it would help)

Skip this when Phase 1 already answered the question — a short session, or a clear
blocked-on-you state. Offer it when the session is long, the arc is tangled, or the user
asks "why".

If they want it (or passed `--deep`), dispatch **one** subagent and say so plainly —
*"a subagent is mining the full transcript for the longer arc"*:

> Read the full transcript at `<path from the digest header>`, and `--format md` output
> if you need more. Report: the arc of decisions and why each was made, approaches tried
> and abandoned (and why), unresolved disagreements, and anything that contradicts the
> current plan. Be concrete, cite turns. Do not summarize everything — only what a person
> returning after two days would need.

A subagent is correct **here** and wrong in Step 1: off the critical path it buys depth;
on it, it would only add latency.

## Step 4 — Progressive enhancements (backoff-gated)

Opt-in extras. Check the ledger before mentioning any of them; it enforces "offer once,
then demote to a protip, then go quiet":

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/nudge.mjs" bump           # once, at the start
node "${CLAUDE_PLUGIN_ROOT}/scripts/nudge.mjs" check hotline  # → full | protip | silent
node "${CLAUDE_PLUGIN_ROOT}/scripts/nudge.mjs" record hotline accepted|declined
```

`full` → make the real offer. `protip` → a single italic footer line. `silent` → say
nothing at all.

| kind | when to consider it | full offer |
|---|---|---|
| `hotline` | **only** when tail state is `BLOCKED ON YOU` | If `hotline:dial` is available, offer to send the user's answer into that session. Confirm before writing into a live session. If not installed, offer to install: `claude plugin install hotline@jtsternberg` |
| `handoff` | session is substantial and the user won't act now | If the `handoff` skill is available, offer to persist this caught-up state as a handoff |
| `wrapper` | any successful catch-up | Offer the shell shim so future catch-ups are one command: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-wrapper.sh" install`. Note permissions are **not** skipped unless they pass `--yolo` |

Do not offer `hotline` when the target session **is** the caller's own session — there is
nothing to relay.

## Related

`sessions-fork` reads the same digest but for a different purpose: priming a session with
another one's context before starting unrelated work, ending on a check-in rather than a
briefing about the target's pending state.

## Requirements

Node 18+ (`node --version`). If missing, say so and stop — the digest cannot run.
