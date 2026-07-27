---
name: sessions-fork
description: "Prime this session with another session's context, then stop and check in. Reads a session's transcript off disk and loads what's transferable — decisions, constraints, dead ends, current repo state — so this session is ready to take on new work. The new work need not be related to the one you read. The source session is never resumed or written to."
when_to_use: |
  Use when the user wants THIS session to inherit another session's context before
  starting something else: "catch up on <id> then we'll work on something",
  "read that session first, I need you up to speed", "fork off that session",
  "get the context from <id> before we start".
  The follow-on work may be unrelated to the session being read — the point is the
  context, not the continuation.
  For a briefing about that session's own pending state, use `sessions-catch-up`.
disable-model-invocation: true
allowed-tools: "Bash(node *) Bash(bash *) Bash(bd *) Bash(git *) Read Grep"
argument-hint: "<session-id|prefix|slug>"
---

# Sessions Fork

Load another session's context into this one, then **stop and check in**.

This is the `handoff` skill inverted. Handoff pushes context *forward* to a future
session; this pulls it *back* from a past one. Either way the goal is a session that knows
what it needs to know before work starts.

**Do not start work.** The next task may have nothing to do with the session you just
read — you cannot infer it, so don't try. Get caught up, report, ask.

> The source session is read-only: never resume it, never `--fork-session` it, never send
> it input. Everything comes off disk.

## Argument

One positional: the session to read — id, id-prefix, slug, or title. If it's missing, run
`--list` and ask which one.

## 1. Read it

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/export-session.mjs" "<target>" --format digest
```

**Read `${CLAUDE_PLUGIN_ROOT}/references/reading-a-digest.md`** for resolution and
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

## 3. Stop

End on the check-in. Don't plan, don't scaffold, don't start.

If the user's next instruction turns out to build on what you read, apply the constraints
and dead ends you just listed. If it's unrelated, the context still cost nothing.
