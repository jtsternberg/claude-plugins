---
name: triage-beads
description: >-
  Autonomously sweep and triage ALL open beads (bd tasks) the way a careful
  engineer would by hand — reconcile each bead against reality (git history,
  passing tests, tool versions, whether its blockers have since closed), CLOSE
  the ones already satisfied with cited evidence, PARK the ones blocked on an
  external resource with a ready-to-run playbook, and SURFACE genuine JT-only
  decisions into an end-of-run report instead of guessing. Use this whenever the
  user wants to triage beads, clean up stale issues, sweep or prune open beads,
  audit the backlog, close out finished-but-still-open tasks, or asks why so
  many beads are piling up — and it is safe to run repeatedly and unattended
  (e.g. from a scheduled agent). Also fires on "triage the backlog", "clear out
  stale beads", "which of these beads are already done", and "auto-triage".
when_to_use: >-
  When open beads have accumulated and need triage: closing ones reality already
  satisfies, parking ones gated on an external resource, and surfacing ones that
  need a human decision. Runs safely on a schedule.
argument-hint: "[--dry-run] [--status <list>] [--label <label>]"
---

# Triage Beads

Sweep every open bead and do the triage a careful engineer does by hand: figure
out which are secretly already done, which are stuck on something you can't
provide, and which genuinely need JT. JT's complaint is that beads pile up and
rot — this skill exists to keep the backlog honest without asking him to grind
through the whole list one at a time.

Optional flags: `$ARGUMENTS`

Codex: if the invocation text above is not populated, use the text after the
skill name. If none is available, run with no flags (full sweep, writes
enabled). The bundled-script path shown below resolves under Claude Code;
wherever it appears, substitute the directory containing this `SKILL.md`.

Parse the flags:
- `--dry-run` — reconcile and classify everything, print the full report, but
  make **zero** writes (no closes, no comments). Use this for the first run in
  an unfamiliar repo, or any time JT wants to preview the plan before acting.
- `--status <list>` — override which statuses to sweep (default
  `open,in_progress,blocked`). Comma-separated.
- `--label <label>` — scope the sweep to one label.

## The one rule everything else serves

**Never trust the bead's own text, and never close on assumption.** A bead is a
claim written in the past. Your job is to check that claim against the repo *as
it is now*. Every close must cite what you actually checked. If you cannot cite
evidence, you do not close — you leave it open. This is the difference between
triage and vandalism.

## Step 1: Build the worklist

Run the collector. It enumerates every non-frozen open bead and — the one piece
of bookkeeping worth doing deterministically — resolves each bead's
dependencies to their *current* status, so you get "this bead's blocker has
since closed" for free instead of re-deriving it once per open bead.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/collect-open-beads.sh" > /tmp/triage-worklist.json
```

Codex: `SKILL_DIR` is the directory containing this `SKILL.md`; substitute it for
the token above. Re-assign `SKILL_DIR` in each block you run — shell state does
not persist between them.

Read `/tmp/triage-worklist.json`. Each bead carries: `id`, `title`,
`description`, `status`, `priority`, `type`, `parent`, `days_since_update`,
`comment_count`, and `deps` with every dependency's live `status` plus
`all_blocking_deps_closed`. Beads are sorted highest-priority-and-stalest first.

`frozen_skipped` counts `deferred`/`pinned` beads left untouched on purpose —
report that number so JT knows they exist, but do not triage them; they are
frozen by his choice.

## Step 2: Reconcile each bead against reality

For every bead, gather evidence *before* deciding anything. Pull the bead's own
acceptance criteria first — `bd show <id> --json` if the description in the
worklist is truncated or you need comments (`bd comments <id>`). Then check
reality with whichever of these the bead's claims call for:

- **Git history.** Has the work already landed? Search commits for the bead id
  and for keywords from its title/AC:
  `git log --all --oneline --grep="<id>"` and
  `git log --all --oneline -S "<distinctive-string-from-AC>"`. A commit that
  implements the AC is strong evidence — capture its SHA.
- **Tests.** If the AC is "X is covered by tests" or "X works", find the
  relevant test file and **actually run it** — do not assume green. Prefer the
  narrowest command that proves the point (the specific suite), and cite the
  pass count. `bash tests/run-all.sh` is the repo-wide gate; read its summary,
  not just the exit code (a SKIP is not a pass).
- **Tool / dependency versions.** For "upgrade X to version N" beads, run
  `X --version` (or inspect the lockfile / manifest) and compare. If the
  environment already reports ≥ N, the bead is satisfied by the environment.
- **Sibling beads.** The worklist already tells you which blockers/deps have
  closed. A closed blocker does **not** by itself mean this bead is done — it
  means this bead is now *unblocked*, so re-check its OWN acceptance criteria
  against current code+tests and decide from there.

Reconciliation is read-only except for beads writes. Running the project's test
suites is expected. **Never** run migrations, deploys, or any state-mutating
command to "prove" a bead — if proving it requires mutating something, that is a
signal to PARK or SURFACE, not to act.

## Step 3: Classify into exactly one bucket

### CLOSE — reality already satisfies the bead's own acceptance criteria

Close only with cited evidence in `--reason`. The legitimate cases:

| Case | What the `--reason` must cite |
|---|---|
| **Satisfied by environment** | The command + its output, e.g. `node --version → v22.3.0 ≥ required v20`. |
| **Blocker closed → AC now met** | The closed dep id **and** the current-code/test evidence that the AC is genuinely met now — not just "blocker closed". |
| **Verified done by passing tests** | The test command + pass count you actually ran, e.g. `tests/foo.test.mjs → 14 passed`. |
| **Superseded / duplicated / obsolete** | The bead/commit/PR that replaced it. Record the relationship with `bd supersede <id> --with <new>` (which closes `<id>` itself) or `bd duplicate <id> --of <canonical>` so the link survives — use these instead of a bare `bd close`. For an obsolete bead with no replacement, `bd close` with the reason it no longer applies. |

Close:
```bash
bd close <id> -r "<evidence: what you checked and what it showed>"
```

For an **epic**: it is done only when all its children are closed *and* its own
AC holds. Check children (`bd show <id> --children` or the worklist `parent`
field) before closing an epic.

If you find yourself wanting to close but can only cite the bead's own text or a
guess — stop. That is UNTOUCHED, or SURFACE if a human needs to weigh in.

### PARK — blocked on an external/physical resource you can't provide

A drive that must be mounted, a service that must be running, a credential only
JT has, hardware that must be attached. Do **not** close these — they are real
work, just not runnable right now. Leave the bead open and add a **ready-to-run
playbook** comment so the next run (human or agent) can execute it the moment
the resource appears:

```bash
bd comment <id> "TRIAGE PLAYBOOK
Gate: <the exact command that confirms the resource is available, and the exact
output that means 'go'>. e.g.  ls /Volumes/Archive && echo READY
Once the gate passes, run:
  1. <exact step>
  2. <exact step>
  3. <verify: exact command + expected result>"
```

**Idempotency:** before adding a playbook, check `bd comments <id>` — if a
`TRIAGE PLAYBOOK` comment is already there and still accurate, leave it. Do not
stack duplicate playbooks every time the skill runs.

### SURFACE — a genuine JT-only decision

Design, UX, scope, or priority tradeoffs. Anything where the "right" answer is a
judgment call about what JT wants, not a fact about the repo. **Do not act and
do not guess.** Collect it for the report with a crisp recommendation and the
specific question. Recommendation ≠ decision: you are handing him a starting
point, not choosing for him.

### UNTOUCHED — none of the above

Not enough evidence to close, no external gate, no decision needed — just open
work that is still open. Leave it exactly as is and count it. Most beads on a
healthy backlog land here; that is fine. Do not manufacture a reason to touch a
bead.

## Step 4: Discovered work

If triage turns up new work (a bug, a follow-up, a missing test), file it and
link it per this repo's bd convention:

```bash
bd create "<title>" --description="<context>" -p <0-4> --deps discovered-from:<id> --json
```

## Step 5: End-of-run report

Always end with this structured report — both a machine-readable block and a
short human summary. This is the deliverable JT reads instead of the full backlog.

```json
{
  "closed":         [ { "id": "...", "case": "env|blocker|tests|superseded", "reason": "<evidence cited>" } ],
  "parked":         [ { "id": "...", "gate": "<the gate command>", "playbook_added": true } ],
  "needs_decision": [ { "id": "...", "recommendation": "<your call>", "question": "<the specific ask>" } ],
  "untouched":      <count>,
  "frozen_skipped": <count of deferred/pinned left alone>,
  "dry_run":        <true|false>
}
```

Then, in prose: lead with the counts (`closed N, parked M, needs-decision K,
untouched J`), then list only the `needs_decision` items in full — those are the
only ones that need JT's eyes. If `--dry-run`, say so plainly and note that
nothing was written.

## Hard rules (the guardrails, restated)

- **Evidence before closing.** No cited check → no close. The reason must name
  the version output, test count, commit SHA, or closed dep id you relied on.
- **Never guess a design decision.** Surface it with a recommendation + question.
- **Idempotent and safe to re-run.** The only writes are bd state changes and
  comments. Closed beads drop out of the next sweep automatically; check
  existing comments before re-parking so playbooks don't stack. A second run
  with no repo changes should close nothing new and add no duplicate comments.
- **No destructive actions.** Beyond `bd close`/`bd comment`/`bd create` and the
  relationship links above, change nothing. Running tests is allowed; mutating
  state to "prove" a bead is not.
- **Respect the repo's bd conventions.** Use `--json`, link discovered work with
  `discovered-from`, and leave `deferred`/`pinned` beads alone.
- **When in doubt, under-act.** A bead wrongly left open costs a glance next
  run. A bead wrongly closed loses real work silently. Bias toward UNTOUCHED and
  SURFACE over a shaky CLOSE.
