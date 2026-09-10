---
name: until
description: "Stop for now and pick this back up when a session limit resets, in THIS session: 'I hit my 5-hour session limit, stop for now and resume this at 9pm when my session resets', 'I'm rate limited, come back at the reset and keep going', 'resume at 9pm where we left off', 'pause on quota and pick this back up at 6am'. Wakes this session at a wall-clock time or after a delay and runs the queued work here, with the context it already has, spending zero tokens while waiting. Also the plain timed case: 'at 9pm run X', 'in 30 minutes do X', 'queue this for later', 'run this review tonight', 'wake me at 6am and ...', 'delayed work', and queueing several jobs at set times. Not cron and not durable — the watcher dies with the session; not a headless or cloud run in a fresh context; not timed delivery into another cmux surface, which is cmux-cli's send-at."
when_to_use: |
  Use first when a session limit, quota, or rate limit forces a pause and the work
  should resume at the reset: "I hit my 5-hour limit — stop for now and resume this at
  9pm when my session resets", "I'm rate limited, pick this back up at the reset",
  "come back at 6am and continue where we left off". The work resumes in THIS session,
  so the context it already has is still loaded and nothing needs re-reading.
  Also for any plain timed or delayed work that must run here and should cost nothing
  while it waits: "review this PR at 9:05pm", "in 20 minutes run the suite and report",
  "queue these three reviews for tonight, spaced out". Also when a payload needs a
  human in the loop at fire time, which a headless or cloud run cannot give it.
  NOT for schedules that must survive this session closing — nothing here does. NOT for
  repeating schedules (cron, the `schedule` skill). NOT for delivering a prompt into a
  different cmux surface, which is cmux-cli's `send-at`.
argument-hint: "<when> <what to run>"
allowed-tools:
  - "Bash(date *)"
  - "Monitor"
---

# until — stop for now, pick it back up in this session

The case this exists for: a 5-hour session limit lands mid-task. The usual options are
both bad — babysit the clock and come back to type "continue" at the reset, or let the
agent poll "is it time yet?" and spend what quota is left on the polling. Instead, stop
for now and arm a shell-side clock watcher that costs zero tokens while it waits, then
wakes **this same session** at the reset time with a self-contained "go" line. The
context is still loaded, so the work just continues.

It covers the plain timed case too: run X at 9pm, run X in 30 minutes, or queue a few
jobs across tonight spaced apart.

`$ARGUMENTS` carries the *when* and the *what*: a time or delay, plus the work to run
when it arrives.

Codex: if that token is not substituted, take the when and the payload from the text
following the skill name in the current request.

This is rung 2 of the `patient-waiting` ladder with the clock as the watched condition.
That skill owns the ladder and the hard rules; read it and don't restate it here.

## Three wrong answers

- **Shell to a headless `claude`.** `nohup claude -p "/review-pr …" &` works and is
  wrong: it runs in a context-free throwaway session with no human in the loop, so
  nothing that happens is visible or steerable. `at` is not a fallback either — on
  macOS `atrun` ships unloaded.
- **`/schedule`, `RemoteTrigger`, cloud routines.** They spawn an isolated cloud
  session with its own checkout: not this session, not this context, not this machine.
- **`ScheduleWakeup`.** Model-in-the-loop polling — a full-context turn per wake to ask
  whether it's time yet. `patient-waiting` forbids it for exactly this.

Also not `send-at` (cmux-cli), the closest relative and the inverse: that one delivers a
prompt *into another cmux surface* at a target time and is bound to cmux ancestry.
`until` targets **self**, needs no cmux, and runs the payload rather than typing it
somewhere.

## Mechanism (Claude Code)

A `Monitor` with `persistent: true` running a shell loop that polls the wall clock. The
harness runs the script shell-side and invokes the model only when a line is emitted:
zero tokens until it fires. Rung 2 rather than rung 1 (a backgrounded `until` loop)
because a wait measured in hours outlives a plain background task — those get reaped on
session handoff, and this one has to be alive at a fixed moment, not eventually.

```
Monitor({
  description: "clock hitting 9:05pm to trigger the queued review",
  persistent: true,
  timeout_ms: 3600000,
  command: `TARGET=$(date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-09 21:05:00" +%s)
while [ "$(date +%s)" -lt "$TARGET" ]; do sleep 30; done
echo "FIRE at $(date '+%-I:%M%p') — run /review-pr on https://github.com/OWNER/REPO/pull/701 now"`
})
```

Five things there are deliberate:

1. **Epoch comparison in a loop, not one long `sleep`.** `sleep 11280` does not advance
   while the Mac's lid is shut — it fires late by however long the machine slept.
   Comparing `date +%s` to a fixed target lands within one poll interval of the real
   time regardless.
2. **`date -j -f` is the BSD/macOS form.** GNU `date -d` fails here; on a GNU box it
   is the other way round, so check `uname` before pasting either.
3. **The loop exits after exactly one `echo`.** Exit ends the watch, so exactly one
   notification fires. `while true` would stay armed after firing.
4. **The emitted line is a self-contained instruction to your future self** — it names
   the skill or command and the full target (URL, path, ticket id). The notification
   arrives bare, with none of this reasoning attached, so anything the payload needs
   has to be inside the line.
5. **Pass the max `timeout_ms` (3600000) anyway.** `persistent: true` makes it moot
   today, and that is the point: if `persistent` is ever dropped, a one-hour cap fails
   loudly instead of a five-minute default firing silently early.

## Parsing `<when>`

Resolve to an epoch-seconds target before arming anything. Run one of these, read the
epoch off stdout, and paste that literal number into the watcher — each is written to
start with `date` so the `Bash(date *)` grant actually covers what gets executed.

```bash
# absolute, same day: "9:05pm" / "21:05"
date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 21:05:00" +%s
# absolute with an explicit date: "2026-09-10 09:00"
date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-10 09:00:00" +%s
# relative: "in 20 minutes" / "in 2h"
date -v+20M +%s
```

An absolute time already past today rolls to tomorrow — re-resolve it with tomorrow's
date, or add 86400 to the epoch.
Say so when you do it, and say the horizon out loud: an overnight target means the
session, the machine, and the machine's wakefulness all have to survive until then. If
the human wants overnight, that is the moment to tell them this can't guarantee it.

## Say this when you arm it

- **A `Monitor` dies with the session.** It survives longer than plain background tasks
  — background-bash reaping is what rung 2 exists to beat — but if the session is gone
  at fire time, nothing fires and there is no fallback and no catch-up.
- **The Monitor task ID**, so the human can cancel with `TaskStop`.
- **The exact target time and the exact payload**, in the words the notification will
  carry.

## On fire

Run the payload. **The notification is the go signal** — reporting that it arrived and
stopping is the failure mode this skill exists to prevent.

Resolve the payload's skill or command name against the skill list for the current
working directory rather than guessing it. Project skills can be exposed under a
prefixed name from a subdirectory and a bare name from the repo root, so the name that
worked when you armed the watcher is not automatically the name that works now.

## Queueing several

Up to about three: one `Monitor` each. Each exits after its own fire and each
notification is unambiguous. Simplest thing that works.

More than that: one watcher holding a tab-separated `epoch<TAB>payload` schedule table,
emitting a line per due row and exiting once the last has fired.

```bash
while IFS=$'\t' read -r ts payload; do
  while [ "$(date +%s)" -lt "$ts" ]; do sleep 30; done
  echo "FIRE — $payload"
done <<'ROWS'
1757466300	run /review-pr on https://github.com/OWNER/REPO/pull/701 now
1757469900	run /review-pr on https://github.com/OWNER/REPO/pull/702 now
ROWS
```

Space heavy payloads apart. A multi-agent review is a heavy job and two firing on top of
each other interleave badly; 20 minutes is a reasonable gap for review runs, not a
universal number. Size the gap to how long one payload actually occupies the session.

## Worked example — resuming after a session limit resets

A budget watcher (or the harness) reports the 5-hour session limit is close and names
the reset time. The work in flight is a multi-step review that is not finished.

1. **Pause at the warning, not at exhaustion.** Finish the step in flight and stop
   there. Once a request is actually rate limited there is no turn left to arm anything,
   so the whole play depends on arming while quota remains.
2. Resolve the reset time to an epoch target and arm one `Monitor` whose emitted line
   names the resumption point, not just "continue":
   `FIRE — quota refilled, resume the review of https://github.com/OWNER/REPO/pull/701 at the security pass (step 3 of 5) now`.
3. Report the task ID, the exact reset time, and that the watcher dies with the session.
4. On the notification, keep going. **No resume note is needed** — this is the same
   session and its context is still loaded. A resume note is for a pause that ends in a
   *fresh* session, which is what a context-window pause needs and this is not.

## Worked example — a queue of PR reviews

The human hands over three PRs and the times they want them reviewed, and wants the
reviews run here so they can watch and steer before anything is published.

1. Resolve each time to an epoch target; confirm the review command's name for this cwd.
2. Arm one `Monitor` per PR (three is inside the one-per-job range), each emitting
   `FIRE — run /review-pr on <full URL> now`.
3. Report the three task IDs, the three fire times, and the fact that all three die with
   the session.
4. On each notification, run the review for that URL. Don't batch it with a later one
   that hasn't fired.

## Codex

`Monitor` is Claude Code only, and Codex has no wake-from-idle primitive that resumes
in-pane. Its only in-session wait is a blocking `functions.wait` on a yielded exec cell:

```bash
target=$(date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-09 21:05:00" +%s)
until [ "$(date +%s)" -ge "$target" ]; do sleep 30; done
```

That blocks the whole turn, so it is honest only for short horizons — minutes to about
an hour. For anything longer there is no Codex path that keeps this session's context
and costs nothing while waiting; say that and let the human choose between waiting with
a blocked turn and nudging you themselves. The zero-token-until-fire property of this
skill is **Claude-Code-specific**.
