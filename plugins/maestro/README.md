# Maestro

Orchestration stance for a main agent that oversees delegated work instead of doing it. Three skills:

- **[`conduct`](skills/conduct/SKILL.md)** — the boss-not-doer stance for an implement → review → address pipeline.
- **[`patient-waiting`](skills/patient-waiting/SKILL.md)** — the zero-token discipline for waiting on anything.
- **[`your-cue`](skills/your-cue/SKILL.md)** — a read-only briefing of every live agent session, one cue per workstream.

## Install

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install maestro@jtsternberg
```

Invoke as `/maestro:conduct`, `/maestro:patient-waiting`, and `/maestro:your-cue` in Claude Code, or `$maestro:conduct`, `$maestro:patient-waiting`, and `$maestro:your-cue` in Codex. Bare names are prose identifiers only.

## Skills

### `conduct`

You are the boss, not the doer: your cycles go to choosing what happens next, writing work orders, verifying results, and talking to the human — edits, searches, test runs, and reviews all happen in delegated agents. Each pipeline phase gets a **fresh agent in a fresh session**, because an implementer that reviews its own work and a reviewer that addresses its own review both lose the skeptical context that made the phase worth running. Fresh means defeating the session-routing cache too — dispatch the next phase with `--fresh` — or the "reviewer" is silently the implementer resumed.

Work orders carry what a fresh context can't cheaply rediscover: verified facts (including known inaccuracies in the source material), hard constraints as behaviors rather than vibes, **every environment trap a predecessor already hit**, tripwires armed with the evidence to self-settle them, and any charter text embedded verbatim. Reports come back as claims, not conclusions — check the diff, PR state, and CI yourself before telling the human a phase succeeded. Every message to the human ends with `Next for you: <the single action>`, never a menu.

It binds to whatever is installed: `hotline` to dispatch into another workspace so that repo's own CLAUDE.md and skills load, `cmux-cli` to give each phase a visible, resumable surface the human can step into. With neither, it falls back to in-process subagents for quick mechanical work and headless sessions launched in the owning repo for substantial phases.

**Triggers** when the session's job is overseeing delegated agents — orchestrating a multi-agent workstream, running boss mode, delegating a pipeline — rather than doing the work.

### `patient-waiting`

A waiting ladder you never skip down: a background bash `until` loop first, the `Monitor` tool with `persistent: true` when background tasks keep getting reaped, and if both keep dying, **stop and hand the loop to the human** rather than falling through to model-in-the-loop polling. The rule underneath it all: never machine-poll a human. If the event is human-triggered — a review submitted, a doc approved, "when I'm ready" — they can close the loop by speaking, and a scheduled model wake adds cost and nothing else.

`ScheduleWakeup` loops are reserved for machine-paced state neither watcher can see, and even then come with three backstops: max three quiet iterations, no off-hours polling, and a quiet-poll count in every reschedule reason so drift stays visible. The skill exists because a killed watcher once got "recovered" into an hourly self-reschedule that ran for a week — roughly 140 full-context premium-model turns spent confirming nothing had changed.

**Triggers** before setting up any poll, watch loop, recurring check-in, or `ScheduleWakeup` loop — on "check in on X", "watch for Y", "tell me when Z", "poll", "monitor this" — and whenever a background watcher was killed and you're about to work around it.

### `your-cue`

A read-only briefing across every live agent session, answering the question a list of running panes never does: what does each workstream need from you *now*. Catch-up is the input; the cue is the product. Every workstream ends with `Your cue:` — a concrete verb (answer, approve, review, review and close, resume, clarify, close, bury) or `Your cue: nothing — <reason>`, so "nothing needed" is a conclusion stated rather than a line omitted — and the whole briefing ends with a single prioritized `Next for you:`, never a menu.

It takes no arguments and sweeps whatever is reachable: `graveyard candidates --json` as the unified fast path, or `herdr agent list` plus cmux tree/sidebar state as the portable one, enriched only where a row is missing a visible name or status. When just one host answers it **stops and asks** rather than briefing half the fleet as if it were the fleet, and a partial run the user approved carries a `Coverage` section. Hotline callees nest beneath their caller, filtered to sessions actually in the live inventory, because the call registry is append-only and unpruned; most rows are stale.

Unclear rows get a bounded transcript summary — `--window 8 --max-chars 8000`, capped at five per run with the remainder listed by visible locator. Each one is a cheap subagent of its own, dispatched to route to the model-invocable `sessions-catch-up` and report three sentences, so the briefing itself never reads a transcript. Everything it runs is a read: no focus stealing, no keystrokes into a live REPL, no cleared notifications or scrollback. Burial is a *cue*, requiring both a finished transcript and Graveyard's `buryable`; execution waits for the user.

**Triggers** when the user wants to know what their agents are doing, what is waiting on them, or what finished while they were away — a morning briefing, a status sweep of delegated work, a catch-up across workspaces.
