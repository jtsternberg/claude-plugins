---
name: sessions-catch-up
description: "Catch up on another Claude Code session without touching it. Given a session id, prefix, or slug, distills that session's transcript into a short briefing — where the work landed, what's blocking, and what's waiting on the user. Runs as a sidecar so the target session's context is never modified."
when_to_use: |
  Use when the user wants to get back up to speed on a DIFFERENT session:
  "catch me up on <session-id>", "what was I doing in that session",
  "what's waiting on me in <id>", "summarize session <id>",
  "I stalled out on this a couple days ago, where did we land".
  Typically the target is a stalled session the user is returning to.
  Not for summarizing the CURRENT conversation, and not for git/branch
  catch-up (that is the unrelated /catchup command).
disable-model-invocation: true
allowed-tools: "Bash(node ${CLAUDE_SKILL_DIR}/scripts/*) Bash(bash ${CLAUDE_SKILL_DIR}/scripts/*) Bash(bd *) Read Grep"
argument-hint: "<session-id|prefix|slug> [--deep] [--window N]"
---

# Sessions Catch-Up

Read another session's transcript off disk and brief the user on it. **Speed is the
product.** The user could scroll back and read the whole thing themselves — if this
takes as long or requires as much reading, it has failed.

So: **answer first, detail second.** Phase 1 is a short prose briefing, delivered
immediately. Phase 2 is optional and only happens if the user wants the longer arc.

> Never resume, fork, or send input to the target session. This is read-only, off
> disk. `/export` is not usable here — it is a TUI-only command
> (`claude -p "/export …"` answers *"/export isn't available in this environment"*),
> and driving it by typing into a live REPL would append a turn to the target.

## Arguments

Parse `$ARGUMENTS`:

- **first positional** — session id, id-prefix, slug, or title. Required.
- `--deep` — run Phase 2 without asking.
- `--window N` — turns kept near-verbatim (default 12).

If no target was given, run `--list` (below) and ask which one.

## Step 1 — Digest (one command, always)

```bash
node ${CLAUDE_SKILL_DIR}/scripts/export-session.mjs "<target>" --format digest --fast
```

Resolution is handled for you: exact id → id-prefix → slug/title, disambiguated by
proximity to the current cwd. **Ambiguity is reported, never guessed** — if the script
exits 1 with a candidate list, show that list and ask which one. If it exits 1 with
"No session matches", run `--list` and offer the nearest few by name.

```bash
node ${CLAUDE_SKILL_DIR}/scripts/export-session.mjs --list   # id · idle · slug · cwd
```

Read the digest output directly from the command result. It is already ~50–500x smaller
than the transcript, so **do not** pipe it through a subagent — that adds a round-trip
to the one thing that must be fast.

## Step 2 — Brief the user (this is the deliverable)

Lead with prose. **2–3 paragraphs**, in plain language, answering: what was this session
doing, how far did it get, and what is the state right now. Then the two short lists.

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

Rules:

- **Lead with the tail state.** The digest's `## ⏳ Tail state` block is the single most
  important signal — `BLOCKED ON YOU`, `YOUR MESSAGE MAY BE UNANSWERED`, or
  `INTERRUPTED MID-TURN` each mean something different. Say which, in the first
  paragraph.
- **Trust the live bead status over the transcript.** The digest resolves referenced
  beads via `bd show`, so a bead the session left "open" may since have closed. Report
  what is true now.
- **Do not fabricate.** A thin transcript gets a thin briefing. Say "the transcript
  doesn't show why" rather than inventing a reason.
- Keep it skimmable. No tool-by-tool narration — the user wants orientation, not a replay.
- If the digest has a `## Compaction summary`, say so: detail before that point exists
  only as that summary.

## Step 3 — Offer the deep pass (only when it would help)

Skip this entirely when Phase 1 already answered the question — a short session, or a
clear blocked-on-you state. Offer it when the session is long, the arc is tangled, or
the user asks "why".

If they want it (or passed `--deep`), dispatch **one** subagent and say so plainly —
*"a subagent is mining the full transcript for the longer arc"*:

> Read the full transcript at `<path from the digest header>` plus
> `--format md` output if you need more. Report: the arc of decisions and why each was
> made, approaches tried and abandoned (and why), unresolved disagreements, and anything
> that contradicts the current plan. Be concrete, cite turns. Do not summarize
> everything — only what a person returning after two days would need.

A subagent is correct **here** and wrong in Step 1: off the critical path it buys depth,
on it would only add latency.

## Step 4 — Progressive enhancements (backoff-gated)

These are opt-in extras. Check the ledger before mentioning any of them; it enforces
"offer once, then demote to a protip, then go quiet":

```bash
node ${CLAUDE_SKILL_DIR}/scripts/nudge.mjs bump              # once, at the start
node ${CLAUDE_SKILL_DIR}/scripts/nudge.mjs check hotline     # → full | protip | silent
```

`full` → make the real offer. `protip` → a single italic footer line, nothing more.
`silent` → say nothing at all.

Record the outcome so the ladder advances:

```bash
node ${CLAUDE_SKILL_DIR}/scripts/nudge.mjs record hotline accepted|declined
```

| kind | when to consider it | full offer |
|---|---|---|
| `hotline` | **only** when tail state is `BLOCKED ON YOU` | If `hotline:dial` is available, offer to send the user's answer into that session. Confirm before writing into a live session. If not installed: offer to install it — `claude plugin install hotline@jtsternberg` |
| `handoff` | session is substantial and the user won't act now | If the `handoff` skill is available, offer to persist this caught-up state as a HANDOFF doc |
| `wrapper` | any successful catch-up | Offer the shell shim so future catch-ups are one command: `bash ${CLAUDE_SKILL_DIR}/scripts/install-wrapper.sh install`. Mention that permissions are **not** skipped unless they pass `--yolo` |

Protip form, for reference:

> _protip: `claude plugin install hotline@jtsternberg` if you want me to reply into that session directly._

## Digging deeper without a subagent

Follow-up questions usually don't need Phase 2. The digest names the transcript path;
`Grep` it directly, or re-run with `--format md` (full readable transcript),
`--window 40`, or `--compaction-full`. Reserve
`claude --resume <id> --fork-session` as a last resort only — it replays the entire
transcript into a fresh context and costs a full prefill.

## Requirements

Node 18+ (`node --version`). If it's missing, say so and stop — the digest can't run.
