# Safe divergence: doing new work off someone else's session

Read this before editing anything when the work was informed by another session. Used by
`sessions-fork`; `sessions-catch-up` points here if a read-only catch-up turns into work.

## The hazard

Reading a transcript is always safe — it is a file on disk, and nothing here ever
resumes, forks, or sends input to the target session.

**Editing is a different question.** If the target session is *live* in the same repo,
and you start editing that same working tree, two agents now share one checkout: one
staging area, one `git status`, one set of open file handles. Symptoms are ugly and
confusing — a commit that captures half of someone else's work, a test run against files
that changed mid-run, an agent reverting an edit it never made.

The digest gives you exactly what you need to decide, in its header:

```
- **cwd** `/path/to/repo` · branch `main`
- **last activity** 4m ago (active)
```

## The decision

| Target's liveness | Same repo as you? | Do this |
|---|---|---|
| `active` (<5 min) | yes | **Isolate.** Worktree, or wait. Do not edit in place. |
| `recent` (<60 min) | yes | **Isolate** unless the user confirms that session is finished — "recent" often means "still going, just thinking". |
| `idle` (hours/days) | yes | Editing in place is normally fine. Say which branch you are on before you start. |
| any | no (different repo) | No conflict. Proceed. |

When in doubt, isolate: a worktree costs seconds, and untangling two agents in one
checkout costs much more.

## Isolating

The repo already has tooling for this — do not hand-roll `git worktree`:

- **`git-tree:create-git-tree`** — creates a worktree in a parallel directory and
  symlinks `node_modules`, `vendor`, and `.env` so the new tree is immediately usable.
- **`superpowers:using-git-worktrees`** — the process skill, if it is available.

Announce the worktree path and the branch. The user needs to know where the work went;
a silently-relocated checkout is its own failure mode.

## Carrying context across without carrying mistakes

A digest tells you what *happened*, not what was *right*. When branching work off it:

- **Settled** — decisions already made with reasons. Do not relitigate; say you are
  building on them.
- **Still open** — questions the session never answered. These are your real inputs.
- **Constraints that carry over** — the ones that will silently break your work if
  ignored: a chosen backend, a naming contract, an API version, a marker string.
- **Dead ends** — approaches tried and abandoned. The single highest-value thing to
  inherit, because rediscovering them costs the most. `thinking` is not persisted, so if
  the reason was never written down it is gone: say "the transcript doesn't say why"
  rather than guessing.

## Do not touch the source session

Never write into the target to "sync" the fork — no `hotline:dial` to tell it what you
are doing, no editing its handoff. If the two lines of work need to converge, that is a
decision for the user, and a normal git merge afterwards.
