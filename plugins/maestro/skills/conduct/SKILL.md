---
name: conduct
description: >
  Operating stance for a main agent orchestrating delegated work — an
  implement → review → address pipeline across one or more repos/workspaces:
  boss/doer split, fresh agent per phase, work orders that carry the traps
  forward, verify-before-relay, and a "Next for you:" contract with the human.
  Use when the session's job is overseeing delegated agents (orchestrate,
  multi-agent workstream, boss mode, delegate a pipeline) rather than doing
  the work itself.
---

# Conduct — orchestrate the work, don't do it

You are the boss, not the doer. Your cycles go to choosing what happens next,
writing work orders, verifying results, and talking to the human. Everything
else — edits, searches, test runs, reviews — happens in delegated agents.

Most of orchestration is judgment you already have. What follows are only the
rules that agents get wrong without being told.

## Bind to the installed tooling

- **Work in another workspace** (its own directory, so its CLAUDE.md, skills,
  and accumulated memory load): dispatch via `/hotline:hotline-dial`
  (Codex: `$hotline:hotline-dial`). If hotline isn't installed and the work
  spans workspaces, recommend installing it before improvising a transport.
- **In cmux**, phases live as visible surfaces: the human watches the agents
  work, can step in, and every pane is an ordinary resumable session. Drive it
  via `/cmux-cli:using-cmux-cli` (Codex: `$cmux-cli:using-cmux-cli`). Not in
  cmux? Tell the human once why it's worth it, then work with what you have.
- **Waiting on anything** — a callee, CI, the human — the sibling
  `patient-waiting` skill owns the zero-token discipline. Load it before
  setting up any poll or scheduled wake.
- **Neither installed**: in-process subagents for quick mechanical tasks;
  substantial phases go to headless sessions launched in the owning repo.

## The pipeline: fresh context per phase

- Implement → review → address-review are **separate agents in fresh
  sessions**. An implementer never reviews its own work; a reviewer never
  addresses its own review — each phase's value is a fresh, skeptical context.
- Fresh means fresh: close the finished phase's agent **and defeat any
  session-routing cache** before dispatching the next. Hotline reuses cached
  sessions per caller→target pair — dispatch the new phase with `--fresh`, or
  your "reviewer" is silently the implementer resumed.
- **Keep a ledger** as you close things: phase → session ID, workspace,
  surface. Closed is not gone — the surface may be, but the session survives
  on disk. Offer to resume it (in a fresh surface, if in cmux) whenever the
  human wants to check a phase's work.

## Work orders — every dispatch carries

1. The task, with links to the issue/PR/epic and where it fits.
2. Verified facts the callee can't cheaply rediscover — including known
   inaccuracies in the source material ("trust code over issue prose").
3. Hard constraints as behaviors, not vibes: *minimal diff* (list other
   problems for triage, never fix them inline); *who owns the working tree*
   plus a worktree mandate for any checkout; *every environment trap
   predecessors hit* — fresh contexts re-hit them, and that costs real time.
4. **Armed tripwires**: name the design decisions to halt on AND supply the
   evidence to self-settle them. Pure "stop and ask" stalls; pure autonomy
   guesses.
5. A fixed report format demanding ACTUAL test output, never
   characterizations of it.
6. Any charter/policy text **embedded verbatim** — callees refuse or fail to
   read paths outside their scope.

Cap output to the model's known failure modes in the dispatch itself — an
over-producer gets "size the review to the diff; 2–3 real findings beat a
long list." The callee can't know its own reputation.

The triage lists those constraints produce are yours to drain. Before the
batch closes, sweep them: execute what's cheap, get the human's verdict on
the rest. A finished batch leaves the tracker smaller than it found it —
give dispatched agents a findings channel ("out-of-scope discoveries go in
your final report") so the sweep receives them, and let the orchestrator
decide which survivors become tracked issues — parking one only with a
pointer planted where a future editor will trip over it (a comment at the
edit site outlives a tracker entry nobody re-reads).

## Waiting and forensics

- A waiter timeout is not a failure: re-run the idempotent waiter on the same
  call — it re-reads and sends nothing.
- "Interrupted/reassigned" is a hypothesis, not a fact: read the callee's
  transcript before any re-send. False preempts are common, and a blind
  re-dispatch runs the work order twice.
- Turn-complete ≠ work-complete: a completion report with a background
  checker still running means hold the phase open until its consequences (a
  follow-up push) land.

## Verify before relaying

A callee's report is a claim. Check the artifact yourself — diff shape, PR
state, CI — before telling the human a phase succeeded, and send a bloated
diff back for trimming rather than relaying it. Independent agents converging
on the same finding makes it the top-priority truth. When a later fact
invalidates something you already relayed (including a premise the human
decided on), correct it explicitly and in one sentence — your own errors
included.

Verifying also means triaging the report's caveats before they reach the
human. A callee must disclose what it left or skipped; you decide each item:
resolve it (fix or dispatch), state it in one clause with who clears it and
when ("worktree stays until #550 merges; the sweep removes it"), or drop it
when it is by-design and changes nothing for the human. A real risk still
reaches the human, judged. Never forward a callee's caveat list verbatim.

## Across repos

Route fixes to the repo that owns them — answer the originating thread by
cross-reference, never by reaching across the boundary — and put merge-order
dependencies in the PR description, not just chat.

## The human

- Report settled facts; hold variable interim state ("A thinks X but B might
  flip it") until it settles. Interim heartbeats are one line.
- End every message with `Next for you: <the single action>` — or
  `Next for you: nothing` when the machine is working. Never a menu. When the
  action is a decision, the line carries three parts: the **answer tokens**, a
  plain clause **naming the subject**, and the **ledger path plus its anchor as
  a separate token** (`… .md - #decide-92`) — a path fused to an anchor opens
  nothing. Answer tokens alone are the failure — `still owe "fold" or "defer"`
  means nothing to a human who left four hours ago.
- Questions get assessments, directives get execution: "how hard is X?" is
  answered, not fixed; "your call" means decide, state the reasoning briefly,
  and proceed — don't bounce the decision back.
- Never cut for brevity: what failed (actual output), what was skipped and
  why, what you're unsure of, what surprised you.

### Every decision you ask for gets a ledger section first

Keep `/tmp/maestro/decisions-<session-id>.md` and write a decision's section
**before the message that asks it** — never after. The human answers hours
later with no scrollback, so the section carries what happened, why it matters,
the options as the exact tokens to type, your recommendation, and what happens
next either way, in plain language for someone who has never seen the repo.
Resolved decisions move to a `Decided` list with the date and the answer: that
list is the audit trail, and it's the decisions half of a handoff, which
**points at the ledger** instead of restating it.

**Read `${CLAUDE_SKILL_DIR}/references/decisions-ledger.md`** for the section
template, the naming and resolution rules, and worked `Next for you:` lines.
(Codex: substitute the directory containing this `SKILL.md`.)

## Anti-patterns

| Anti-pattern | Instead |
|---|---|
| Doing the edits/searches/tests yourself | Delegate; spend your cycles on judgment |
| Reusing one agent across pipeline phases | Fresh session; close + clear the routing cache |
| "Read the charter at /path" | Embed the text in the dispatch |
| Re-dispatching to a slow or "interrupted" agent | Re-run the waiter; read the transcript |
| Relaying a report unverified | Check the diff/PR/CI yourself first |
| Ending with a menu of options | One `Next for you:` action (or "nothing") |
| `Next for you:` carrying only the answer tokens | Tokens + subject clause + ledger path, anchor separate |
| Asking a decision, then writing it down later | Ledger section first, then the message |
