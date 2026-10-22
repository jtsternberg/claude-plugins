---
name: sessions-fork
description: "Prime this session with another session's transferable context (decisions, constraints, repo state), then carry on with the task in hand or check in."
when_to_use: |
  Use when the user wants THIS session to inherit another session's context before
  starting something else: "catch up on <id> then we'll work on something",
  "read that session first, I need you up to speed", "fork off that session",
  "get the context from <id> before we start".
  The follow-on work may be unrelated to the session being read — the point is the
  context, not the continuation.
  Also mid-task, as evidence for work already under way: "<id> — this session says
  otherwise", "read <id>, it hit the same bug".
  For a briefing about that session's own pending state, use `sessions-catch-up`.
disable-model-invocation: true
allowed-tools: "Bash(node *) Bash(bash *) Bash(bd *) Bash(git *) Read Grep"
argument-hint: "<session-id|prefix|slug> [what to do with it]"
---

# Sessions Fork

Load another session's context into this one, then either carry on with the task it was
loaded for or, when there is none, **stop and check in**.

This is the `handoff` skill inverted. Handoff pushes context *forward* to a future
session; this pulls it *back* from a past one. Either way the goal is a session that knows
what it needs to know before work starts.

**Find out whether a task already exists before you read.** Two cases, and they end
differently:

- **Task in hand** — the invocation carries words after the session id ("this session says
  otherwise", "it hit the same bug"), or this conversation already has work under way that
  the fork was plainly called to inform. The forked session is evidence for that task.
  Read it, then go back to the task with the new context.
- **No task yet** — a bare id at the start of a session, or after finished work. The next
  task may have nothing to do with the session you just read — you cannot infer it, so
  don't try. Get caught up, report, ask.

> The source session is read-only: never resume it, never `--fork-session` it, never send
> it input. Everything comes off disk.

## Argument

First positional: the session to read — id, id-prefix, slug, or title. If it's missing, run
`--list` and ask which one.

Everything after it is the user's instruction, not noise — it is what makes the case
**task in hand**. Codex: if the invocation text is not populated, use the text after the
skill name.

## 1. Read it

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/export-session.mjs" "<target>" --format digest
```

**Read `$PLUGIN_ROOT/references/reading-a-digest.md`**, resolving `PLUGIN_ROOT` with the same fallback, for resolution and
ambiguity, what each tail state means, and which signals to trust. Shared with
`sessions-catch-up` so the two can't drift on it.

## 2. Report what transferred

Short. The question you're answering is *"what does this session now know that it didn't
before?"* — not *"what is the status of that other session?"* (that's `sessions-catch-up`).

```
Caught up on <title or slug> — <cwd> (<branch>), <liveness>

<2–3 sentences: what that session was doing and where it got to>

**Worth carrying forward**
- <decisions and why, constraints that bite if forgotten, dead ends already tried>

**Ready when you are — what are we working on?**
```

Two things to get right:

- **Dead ends are the most valuable thing here** — what was tried and abandoned, so it
  isn't retried. `thinking` blocks are empty on disk, so if the reason wasn't written
  down, say "the transcript doesn't say why" instead of inventing one.
- **Don't fabricate.** A thin transcript gets a short report. Say what isn't there.

Mention only if true and relevant:

- The source session is **still active and in this same repo** — worth knowing before
  either of us edits, since two agents in one working tree collide. (`active`/`recent` in
  the digest header.)
- It left something **unfinished or blocked** — the user may or may not care, but they
  should know it's there.

With a task in hand, drop the check-in line: lead with what the forked session changes
about the task (a verdict it overturns, a dead end not to retry), then continue in step 3.

## 3. Continue or stop

**Task in hand:** keep working it, applying the constraints and dead ends you just listed.
Pause only for a real blocker the fork surfaced — most often the source session still
active in this repo, where both of you editing the same files would collide. Then ask about
that blocker specifically ("e3028c10 is live in this repo and touching `.beads/` — leave it
idle while I take this?"), not "what are we working on?"

**No task yet:** end on the check-in. Don't plan, don't scaffold, don't start. If the
user's next instruction builds on what you read, apply the constraints and dead ends you
just listed. If it's unrelated, the context still cost nothing.
