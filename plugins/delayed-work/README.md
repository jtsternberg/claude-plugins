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

It arms a background task running a wall-clock poll loop, so nothing is spent until the target
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

- Claude watchers **die with the session**. Codex detached timers may outlive a turn,
  but need a live queue receiver and existing thread at fire time. Neither is a durable scheduler.
- **A sleeping machine freezes the loop.** No form of this wakes a Mac; a target that
  passes during system sleep fires on wake instead of on time. Add the opt-in
  `--caffeinate` invocation flag to hold the machine awake for the life of the watcher.
  It stops idle sleep but cannot beat a closed lid — leave the lid open.
- Background tasks can be reaped on session handoff. `Monitor` is only a fallback when
  30 minutes or less remain; its accepted `persistent: true` field does not remove that
  cap in Claude Code 2.1.272.
- Codex CLI 0.160.1 supports a detached one-shot wall-clock timer calling
  `codex queue` into the exact current thread, pinned to the Codex home that owns
  that thread. Detect capability before arming;
  enqueue success is separate from observed delivery. See the skill for private
  payload storage, cancellation, logs, and daemon/sleep limits.

**Related:** the `patient-waiting` ladder (in the `maestro` plugin) with the
clock as the watched condition. For a simple timed prompt to one exact cmux surface,
use `cmux-cli:send-at`. To plan and wake other Claude or Codex sessions at a reset,
use `wake-sessions` below. `until` itself targets the current session.

### `wake-sessions`

Schedule this session to wake other existing Claude Code or Codex sessions after a
quota reset. It investigates their identities and available routes first, tells you
the proposed route and time, then uses `until` to wake the caller. At fire time it
rechecks the targets, delivers to the same sessions, and reports what was actually
observed. If a target is gone, it offers a separate resume choice for each known
session rather than automatically opening one.

The caller needs usable quota and its timer receiver at fire time. A scheduled
wake-up is best effort: machine sleep, a missing target, an unavailable transport,
or a rate-limited caller can prevent delivery.

## Example Usage

Claude Code:

```text
/delayed-work:until at 9pm resume the review of PR 701 where we left off
/delayed-work:until --caffeinate at 9pm resume the review of PR 701 where we left off
/delayed-work:until 9:05pm run /review-pr on https://github.com/OWNER/REPO/pull/701
/delayed-work:until in 2h run the full test suite and report failures
/delayed-work:wake-sessions at 3pm wake the Codex session on surface <uuid>
```

Codex:

```text
$delayed-work:until in 30 minutes run the full test suite and report failures
$delayed-work:until --caffeinate in 30 minutes run the full test suite and report failures
$delayed-work:wake-sessions at 3pm wake the Claude session on surface <uuid>
```

## Additional Documentation

- [skills/until/SKILL.md](skills/until/SKILL.md) - Stop for now and resume the queued work in this session at a set time
- [skills/wake-sessions/SKILL.md](skills/wake-sessions/SKILL.md) - Schedule a wake-up for other existing sessions
