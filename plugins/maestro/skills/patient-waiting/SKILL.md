---
name: patient-waiting
description: >-
  Zero-token discipline for waiting on anything — a file/status change, a
  review submit, a PR, CI, a deploy, a human's approval. Use BEFORE setting up
  any poll, watch loop, recurring check-in, or ScheduleWakeup loop, whenever
  the user says "check in on X", "watch for Y", "tell me when Z", "poll",
  "monitor this", or when a background watcher was killed and you're about to
  work around it. Prevents the runaway pattern where the main (possibly
  premium-model) agent wakes on a schedule to read an unchanged status file.
---

# Patient Waiting — wait without burning tokens

One incident to remember: a background `until`-loop watcher kept getting
killed, so the main agent "recovered" by rescheduling itself hourly via
`ScheduleWakeup` to `cat` a status file. The loop had no idle cap and ran for
a week — ~140 full-context premium-model turns spent confirming that nothing
had changed. Every rule below exists because of that.

## The waiting ladder (in order — never skip down)

1. **Background bash `until` loop** (`run_in_background`). Zero tokens while
   waiting; one completion notification when the condition flips.
   ```bash
   until <condition-check>; do sleep 3; done; echo "signal"; <print state>
   ```
2. **`Monitor` tool, `persistent: true`.** The harness runs your poll script
   shell-side and invokes the model ONLY when a line is emitted. Zero tokens
   idle, survives longer than plain background tasks. Use when background
   bashes keep getting reaped (session handoffs kill them). Cover failure
   states too — emit on the watched thing dying, not just succeeding.
3. **Both keep dying → STOP and hand the loop to the human.** One line:
   "the watcher can't survive in this environment — when you've done X,
   nudge me." Do NOT fall through to model-in-the-loop polling.

## Hard rules

- **Never machine-poll a human.** If the event is human-triggered (review
  submitted, doc approved, "when I'm ready", "after my meeting"), the human
  can close the loop by speaking. A scheduled model wake adds cost and
  nothing else. Zero-token watcher or nothing.
- **`ScheduleWakeup` loops are for machine-paced state only** (CI runs,
  deploys, data jobs, remote queues) — and only when neither ladder rung 1
  nor 2 can see the state. Even then, three backstops are mandatory:
  - **Max quiet iterations: 3.** Three polls with no change → stop the loop
    and leave a one-line resume instruction instead of rescheduling.
  - **No off-hours polling.** If the human is asleep, nothing you're waiting
    on them for is happening. Stop; resume on their next message.
  - **Count quiet polls in each reschedule's `reason`** ("quiet poll 2/3")
    so drift is visible in telemetry and to the user.
- **A killed watcher is a blocker, not a license to escalate.** The failure
  of a cheap mechanism never justifies substituting an expensive one of the
  same shape. Name the problem, present options (including "do nothing —
  you nudge me"), and wait.
- **Know what a wake costs.** A main-agent wake is a full-context turn on
  the session's model — possibly the scarcest premium model. A status poll
  is worth zero of those. If the work on wake is `cat file` + "no change",
  the model should not be in the loop.

## Quick decision table

| Waiting on | Mechanism |
|---|---|
| Local file/status flag to flip once | Background bash `until` loop |
| Recurring events (log errors, PR comments) | `Monitor` (persistent) |
| Human action (submit, approve, "when I'm ready") | Watcher from above — or just tell them to nudge you. Never scheduled wakes. |
| CI/deploy the harness can't see | `ScheduleWakeup`, interval matched to the job, max 3 quiet polls |
| Watcher keeps getting killed | Stop. Ask. Don't escalate. |
