# Maestro

Orchestration stance for a main agent that oversees delegated work instead of doing it. Two skills:

- **[`conduct`](skills/conduct/SKILL.md)** — the boss-not-doer stance for an implement → review → address pipeline.
- **[`patient-waiting`](skills/patient-waiting/SKILL.md)** — the zero-token discipline for waiting on anything.

## Install

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install maestro@jtsternberg
```

Invoke as `/maestro:conduct` and `/maestro:patient-waiting` in Claude Code, or `$maestro:conduct` and `$maestro:patient-waiting` in Codex. Bare names are prose identifiers only.

## Skills

### `conduct`

You are the boss, not the doer: your cycles go to choosing what happens next, writing work orders, verifying results, and talking to the human — edits, searches, test runs, and reviews all happen in delegated agents. Each pipeline phase gets a **fresh agent in a fresh session**, because an implementer that reviews its own work and a reviewer that addresses its own review both lose the skeptical context that made the phase worth running. Fresh means clearing the session-routing cache too, or the "reviewer" is silently the implementer resumed.

Work orders carry what a fresh context can't cheaply rediscover: verified facts (including known inaccuracies in the source material), hard constraints as behaviors rather than vibes, **every environment trap a predecessor already hit**, tripwires armed with the evidence to self-settle them, and any charter text embedded verbatim. Reports come back as claims, not conclusions — check the diff, PR state, and CI yourself before telling the human a phase succeeded. Every message to the human ends with `Next for you: <the single action>`, never a menu.

It binds to whatever is installed: `hotline` to dispatch into another workspace so that repo's own CLAUDE.md and skills load, `cmux-cli` to give each phase a visible, resumable surface the human can step into. With neither, it falls back to in-process subagents for quick mechanical work and headless sessions launched in the owning repo for substantial phases.

**Triggers** when the session's job is overseeing delegated agents — orchestrating a multi-agent workstream, running boss mode, delegating a pipeline — rather than doing the work.

### `patient-waiting`

A waiting ladder you never skip down: a background bash `until` loop first, the `Monitor` tool with `persistent: true` when background tasks keep getting reaped, and if both keep dying, **stop and hand the loop to the human** rather than falling through to model-in-the-loop polling. The rule underneath it all: never machine-poll a human. If the event is human-triggered — a review submitted, a doc approved, "when I'm ready" — they can close the loop by speaking, and a scheduled model wake adds cost and nothing else.

`ScheduleWakeup` loops are reserved for machine-paced state neither watcher can see, and even then come with three backstops: max three quiet iterations, no off-hours polling, and a quiet-poll count in every reschedule reason so drift stays visible. The skill exists because a killed watcher once got "recovered" into an hourly self-reschedule that ran for a week — roughly 140 full-context premium-model turns spent confirming nothing had changed.

**Triggers** before setting up any poll, watch loop, recurring check-in, or `ScheduleWakeup` loop — on "check in on X", "watch for Y", "tell me when Z", "poll", "monitor this" — and whenever a background watcher was killed and you're about to work around it.
