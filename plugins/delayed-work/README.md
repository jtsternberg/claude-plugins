# Delayed Work

Hit your 5-hour session limit mid-task? Stop for now and have **this** session pick the
work back up at the reset — with the context it already has, and spending zero tokens
while it waits. Same mechanism covers any "run X at 9pm" or "in 30 minutes" case.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install delayed-work@jtsternberg
```

## Skills

### `until`

The lead use case: a session limit lands mid-task, so you stop for now and resume at the
reset — `until 9pm quota refilled, resume the review of PR 701 at the security pass`.
The alternatives are babysitting the clock to type "continue", or letting the agent poll
"is it time yet?" with the quota that's left.

It arms a `Monitor` running a wall-clock poll loop, so nothing is spent until the target
time arrives; the notification wakes **this** session — context still loaded, so no
resume note is needed — and it runs the payload itself.

It also covers the plain timed case: `until 9:05pm review https://github.com/OWNER/REPO/pull/701`,
`until in 20 minutes run the suite and report`, and queueing several jobs at spaced-out
times.

Pairs with a budget watcher that reports a reset time: the watcher says pause and names
the reset, `until` turns that reset into the wake-up. Arm at the warning, not at
exhaustion — once a request is rate limited there's no turn left to arm anything — and
arm *before* finishing the step in flight, so a limit landing mid-step leaves a watcher
up rather than nothing.

**Honest limits:**

- The watcher **dies with the session**. If the session is gone at the target time,
  nothing fires and there is no catch-up. Not cron, not a durable scheduler.
- **A sleeping machine freezes the loop.** No form of this wakes a Mac; a target that
  passes during system sleep fires on wake instead of on time. Add the opt-in
  `--caffeinate` invocation flag to hold the machine awake for the life of the watcher.
  It stops idle sleep but cannot beat a closed lid — leave the lid open.
- It does survive the rate limit itself: a session that was HTTP 429'd kept its watchers
  running, and the fire at the reset time woke that same session. Events that arrive
  while the session is rate-limited are queued rather than dropped, and land together in
  the first successful turn.
- Zero-token waiting is Claude-Code-specific (`Monitor`). Codex's only in-session wait
  blocks the turn, so it is honest there only for short horizons.

**Related:** rung 2 of the `patient-waiting` ladder (in the `maestro` plugin) with the
clock as the watched condition. For timed delivery of a prompt *into another cmux
surface*, use the `send-at` skill instead — `until` targets the current session and
needs no cmux.

## Example Usage

Claude Code:

```text
/delayed-work:until at 9pm resume the review of PR 701 where we left off
/delayed-work:until --caffeinate at 9pm resume the review of PR 701 where we left off
/delayed-work:until 9:05pm run /review-pr on https://github.com/OWNER/REPO/pull/701
/delayed-work:until in 2h run the full test suite and report failures
```

Codex:

```text
$delayed-work:until in 30 minutes run the full test suite and report failures
$delayed-work:until --caffeinate in 30 minutes run the full test suite and report failures
```

## Additional Documentation

- [skills/until/SKILL.md](skills/until/SKILL.md) - Stop for now and resume the queued work in this session at a set time
