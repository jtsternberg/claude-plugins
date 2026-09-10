# Delayed Work

Defer work to a wall-clock time (or a delay) and have **this** agent session run it then
— with the context it already has, and spending zero tokens while it waits.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install delayed-work@jtsternberg
```

## Skills

### `until`

Invoke `until` with a time and a payload: `until 9:05pm review https://github.com/OWNER/REPO/pull/701`,
or `until in 20 minutes run the suite and report`.

It arms a `Monitor` running a wall-clock poll loop, so nothing is spent until the target
time arrives; the notification wakes this session, which then runs the payload itself.
Covers absolute times, relative delays, and queueing several jobs at spaced-out times.

**Honest limits:**

- The watcher **dies with the session**. If the session is gone at the target time,
  nothing fires and there is no catch-up. Not cron, not a durable scheduler.
- Zero-token waiting is Claude-Code-specific (`Monitor`). Codex's only in-session wait
  blocks the turn, so it is honest there only for short horizons.

**Related:** rung 2 of the `patient-waiting` ladder (in the `maestro` plugin) with the
clock as the watched condition. For timed delivery of a prompt *into another cmux
surface*, use the `send-at` skill instead — `until` targets the current session and
needs no cmux.

## Example Usage

Claude Code:

```text
/delayed-work:until 9:05pm run /review-pr on https://github.com/OWNER/REPO/pull/701
/delayed-work:until in 2h run the full test suite and report failures
```

Codex:

```text
$delayed-work:until in 30 minutes run the full test suite and report failures
```

## Additional Documentation

- [skills/until/SKILL.md](skills/until/SKILL.md) - Wake this session at a wall-clock time and run the queued work
