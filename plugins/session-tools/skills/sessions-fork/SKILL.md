---
name: sessions-fork
description: "Branch new work off another Claude Code session. Reads that session's transcript off disk, turns it into a work-order (what's settled, what's still open, which constraints carry over, which dead ends to avoid), checks whether the target is still live before touching the repo, and isolates in a git worktree when it is. The read is never destructive to the source session."
when_to_use: |
  Use when the user wants to CONTINUE OR DIVERGE from another session's work
  rather than just be briefed on it: "catch up on <id> and then do X",
  "pick up where that session left off but try Y instead",
  "fork that work onto a new branch", "same context, different approach",
  "take what session <id> figured out and apply it to Z".
  For a read-only briefing with no new work, use `sessions-catch-up`.
disable-model-invocation: true
allowed-tools: "Bash(node *) Bash(bash *) Bash(bd *) Bash(git *) Read Grep Edit Write"
argument-hint: "<session-id|prefix|slug> [-- <what to build>]"
---

# Sessions Fork

Take what another session established and build on it — without inheriting its mistakes,
and without two agents fighting over one working tree.

Same reader as `sessions-catch-up`, different ending. Catch-up produces a **briefing**;
this produces a **work-order** and then does the work.

> **The source session is read-only.** Never resume it, never `--fork-session` it, never
> send it input, never edit its handoff. "Fork" here means forking the *work*, not the
> conversation. Everything is read off disk.

## Arguments

Parse `$ARGUMENTS`:

- **first positional** — the source session: id, id-prefix, slug, or title. Required.
- everything after `--` (or the rest of the sentence) — what to build. If absent, produce
  the work-order and ask what they want done before touching anything.

## Step 1 — Read the source

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/export-session.mjs" "<target>" --format digest
```

Note: **no `--fast` here.** Unlike a catch-up, a fork is about to make decisions from
this, so the wider window and fuller detail are worth the extra few hundred milliseconds.

**Read `${CLAUDE_PLUGIN_ROOT}/references/reading-a-digest.md`** — resolution and ambiguity, what each tail state
means, which signals to trust, how to dig deeper. Shared with `sessions-catch-up`; it is
the single source for all of that.

Two cautions that bite harder here than in a catch-up:

- **"Files touched" is a floor, not a list.** It comes from `Edit`/`Write` calls, so
  anything changed by `sed`, a subagent, or a shell redirect is missing. Before building,
  reconcile against `git status` and `git log`.
- **`INTERRUPTED MID-TURN` means work may be half-applied.** Check the repo, not the
  narrative.

## Step 2 — Decide where to work, BEFORE editing

**Read `${CLAUDE_PLUGIN_ROOT}/references/safe-divergence.md` and follow it.** Short version: compare the
digest's `cwd` and liveness against your own cwd. Target `active`/`recent` in the same
repo → isolate in a worktree (`git-tree:create-git-tree`) or wait. Target idle for hours
or days → in place is fine, but say which branch you are on first.

Announce where the work is going before the first edit. A silently relocated checkout is
its own failure mode.

## Step 3 — State the work-order, then confirm

Before writing code, lay out what you inherited. Short — this is a contract, not an essay.

```
## Forking from <title or slug> — <liveness>, <cwd> (<branch>)
Working in: <path> on <branch>   ← worktree, or "in place"

**Settled** (building on, not relitigating)
- <decisions already made, with their reasons>

**Still open**
- <questions that session never answered — these are the real inputs>

**Constraints that carry over**
- <the ones that silently break things: chosen backend, naming contract, API version, marker string>

**Dead ends to avoid**
- <approaches tried and abandoned, and why — or "the transcript doesn't say why">

**Plan**
1. <ordered, concrete>
```

Rules:

- **Do not fabricate a rationale.** `thinking` blocks are empty on disk, so if a reason
  was never written down it is gone. "The transcript doesn't say why" is the correct
  sentence.
- **Settled ≠ correct.** It means decided-with-reasons. If a settled decision looks wrong
  for the new goal, say so explicitly and let the user choose — do not silently diverge
  from it, and do not silently inherit it either.
- If the user already told you what to build, confirm the work-order and proceed. If they
  didn't, stop here and ask.

## Step 4 — Do the work

Normal implementation from here, with two carry-overs from the source:

- Honor the constraints you listed. Re-check them when something fights you — a
  constraint you forgot is the most common way a fork quietly breaks.
- If you hit one of the listed dead ends, stop and say so rather than pushing through it
  again.

If the source session referenced beads, they were re-resolved live in the digest. Do not
reopen or edit the source session's issues; file your own with
`--deps discovered-from:<their-id>` so the lineage is visible.

## Step 5 — Report

State plainly:

- where the work lives (path + branch), and that it is **not** on the source's branch if
  you isolated
- what you built, and which inherited constraints shaped it
- anything that contradicted the source session's assumptions — the most valuable thing
  a fork produces
- how to converge later, if that is wanted: a normal merge. **Never** write into the
  source session to sync it.

## Requirements

Node 18+. `git` for the worktree path. `git-tree:create-git-tree` is optional but
preferred over hand-rolled `git worktree`.
