---
name: every
description: "Recurring reminders and work in THIS session, with zero model calls or tokens between pings: 'remind yourself of this goal every hour', 'set a reminder to do X in 2.5 hours, then repeat every 1.5 hours', 'at 4:30pm do X, then every 90 minutes', 'keep me on track hourly'. Accepts prose, a separate first-fire time and fractional repeat intervals. Uses a native recurring Claude schedule or an independent Codex queue timer, not a chain of model re-arms. List or cancel these reminders here too. Not cloud scheduling or a guarantee across shutdown."
argument-hint: "<first time or delay, optional> <work> every <interval> [stop condition]"
---

# every — recurring work in this session

Set up a recurring schedule once. **Zero model calls and zero tokens between
pings** is the defining contract. The scheduler or timer waits outside the model;
each delivered ping uses tokens to run its payload. Do not implement recurrence
with model-driven re-arming, ScheduleWakeup, or a foreground wait that holds the
agent turn open.

Interpret `$ARGUMENTS` as prose describing the work, first fire and repeat interval.
Codex: if that token is not substituted, use the text following the skill name in
the current request. Do not require flags or a rigid argument order.

Examples (prefix with `/delayed-work:every` in Claude Code or
`$delayed-work:every` in Codex):

- `set a reminder to do X in 2.5 hours, then repeat every 1.5 hours`
- `at 4:30pm review progress toward PR 701, then repeat every 90 minutes`
- `remind yourself of this goal every hour until it is complete`

## Resolve the request

1. Read the actual local clock. Resolve the first fire to an explicit calendar
   timestamp with UTC offset. Parse the first delay independently from the repeat
   interval: 2.5 hours is 150 minutes; 1.5 hours is 90 minutes. With only an interval,
   first fire is one interval from now. Do not run immediately unless requested.
   Follow `until`'s time parsing rules for an unspecified date or a past clock time.
2. Preserve the exact work, goal, named targets, reporting policy and stop condition.
   A goal reminder stops when that goal is actually complete; otherwise continue
   until cancelled or the scheduler expires. Do not invent a quota threshold.
3. Confirm the resolved first fire, timezone, repeat interval, payload and stop
   condition when reporting the armed schedule. Disclose rounding or native timing
   limits; never silently turn 90 minutes into hourly or every two hours.
4. For a status-only wait, follow `patient-waiting` and use an event watcher when
   possible. An explicitly requested periodic goal review does useful reasoning
   on each ping; do not replace it with silent status polling.

Read the sibling `until` skill for identity checks, timer capabilities, private
payload storage, sleep/receiver limits and one-shot cancellation. Resolve it through
the current skill list. If needed, read it at the path below.

Codex: substitute the installed plugin directory for the path below.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/until/SKILL.md`.**

## Claude Code — native recurrence

Require the live `CronCreate`, `CronList` and `CronDelete` tools. Check availability
in this session rather than assuming it from a version. If unavailable, report the
missing capability; do not fall back to a re-arming chain or a background Bash
process that merely prints repeatedly. Bash completion wakes once, not per line.

Use a single `until` one-shot for the first fire. Its payload must carry the full
request, the original first timestamp, interval, stop condition and the instruction
to install the native recurring schedule **once**, then perform this occurrence.
This bootstrap permits an arbitrary initial delay without any early recurring
pings. It is the only startup wake: subsequent occurrences never re-arm themselves.
Report the bootstrap task ID so it can be cancelled before the first fire.

Before arming, save a private reminder record outside git with the first timestamp,
interval, payload, cancellation flag, native IDs and last handled slot. Carry its
absolute path in the bootstrap and every occurrence prompt. Set cancellation in
this record before stopping jobs, so an already queued bootstrap cannot create them.
At first fire check cancellation, then record the latest due local wall-clock slot
as handled before installing jobs. Every native occurrence computes the latest due
slot from the original first timestamp and interval, skips an already handled slot,
and records it before doing work. This also suppresses a duplicate in the bootstrap
minute. Missed slots are coalesced, not replayed.

At that first ping, compute native cron expressions with the planner below. Run
the planner before arming the bootstrap too, so an unsupported cadence fails early.
The example's first time is illustrative; substitute the resolved request values.

Codex: this path resolves under Claude Code; substitute the installed plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
python3 "$PLUGIN_ROOT/scripts/recurrence.py" --when "2026-11-13T16:30:00-05:00" --every 5400
```

For each returned expression call `CronCreate` with `recurring: true` and a
self-contained occurrence prompt. A 90-minute cadence needs two expressions,
alternating within a three-hour cycle; one `*/90` expression is invalid. Save all
returned IDs as one logical reminder in the session record. If creation partly
fails, delete the entries just created and report failure. Do not leave a partial
schedule. Use `CronList` to verify the IDs, expressions and prompts; report the
IDs and the native next-run time when available. Do not recreate existing IDs
when an occurrence arrives or the bootstrap notification is repeated.

Native cron uses local wall-clock minutes, runs between turns and adds jitter.
Resolve Claude's first target to a whole minute (round up and disclose that change
if a relative delay includes seconds); do not silently truncate the phase.
The planner supports whole-minute intervals that divide a 24-hour day, including
90 minutes; it refuses others rather than rounding their cadence. Report that
limitation when relevant. Check that all expressions fit the available native task
slots before arming and again at first fire. Daylight-saving changes can change elapsed gaps. Native
recurring jobs currently expire after seven days. Report the actual expiry and
timing shown by the live harness, and do not silently renew expiry forever.
See [the native scheduler contract](https://code.claude.com/docs/en/scheduled-tasks).

## Codex — independent recurring timer

Follow `until`'s live queue capability, exact current thread and owning Codex-home
checks. Write the full occurrence prompt to a private UTF-8 payload file outside
git, using a literal file-writing tool. Preserve the sender prefix requested by
the caller, or use `[Delayed-work timer]`. Do not put payload text in shell source.

Arm the shared timer once with the resolved first timestamp and interval in whole
seconds (minimum 60). Fractional hours such as 1.5 hours become 5400 seconds.

Codex: this path resolves under Claude Code; substitute the installed plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
python3 "$PLUGIN_ROOT/scripts/codex_timer.py" arm --when "2026-11-13T16:30:00-05:00" --every 5400 --payload-file "/absolute/path/to/private-payload.txt"
```

Report the returned job directory, PID, thread, pinned home, first target, interval
and expiry. The detached Python process waits on wall time, queues each ping and
advances the schedule itself. It runs no model and never executes the work.
It preserves the phase anchored to the first target, skips missed intervals after
sleep, and allows only one outstanding ping. The receiver acknowledges a ping by
removing that job's `pending` file after handling it. A busy session or quota limit
therefore does not accumulate a backlog. A timeout or queue failure stops recurrence
for reconciliation rather than retrying a possibly delivered ping. Jobs expire
after seven days. Enqueue acceptance is not proof the receiver acted on it.

## On each ping

Check cancellation, expiry and the stop condition before doing the work. For Codex,
read this job's status and cancellation marker first; cancellation wins over an
already queued ping. For Claude, verify the logical reminder's IDs are still active.
Execute the work within existing authorization. A reminder grants no extra authority
to publish, merge or message anyone. Recurrence is already installed: **do not
re-arm it**. On completion, cancel all entries for this reminder.

Honor payload-specific quota and reporting rules. For example, if the caller asked
to skip work at 80% quota, inspect a real available quota signal; do not guess a
percentage. Skip that occurrence when the condition holds, acknowledge it on
Codex, and leave recurrence running. Report an unavailable quota signal honestly.
Only-message-on-change suppresses an update to the human, not the model turn.

An hourly goal review might ask for the latest measured verdict and its age, the
critical job and what shortened it, work to drop or hand off, and unresolved agent
blockers. Carry those questions only when requested; this skill accepts any work.

## List, cancel and limits

List only this session's known logical reminders. On Claude use `CronList`; before
the first fire, inspect the bootstrap task. Cancel its pending bootstrap and every
native ID belonging to the reminder, setting the record's cancellation flag first.
A cancelled bootstrap must not install jobs.
On Codex inspect the returned job's metadata/status and create its `cancel` marker
using a literal file tool. This stops future sends within one timer poll; an already
queued ping must observe the marker and skip its payload. Do not kill a stale PID
without checking identity. A stopped/failed job needs explicit reconciliation and a
new arm, not deletion of `pending` to force an uncertain resend.

Both mechanisms need a running machine and live receiving session. Sleep delays
pings; shutdown is not durable scheduling. No implicit caffeination: holding the
machine awake requires explicit consent and a separate bounded process, as `until`
describes. Neither a new cloud session nor headless model polling is a substitute.
