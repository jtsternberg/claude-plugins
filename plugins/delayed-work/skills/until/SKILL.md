---
name: until
description: "Stop for now and pick this back up when a session limit resets, in THIS session: 'I hit my 5-hour session limit, stop for now and resume this at 9pm when my session resets', 'I'm rate limited, come back at the reset and keep going', 'resume at 9pm where we left off', 'pause on quota and pick this back up at 6am'. Wakes this session at a wall-clock time or after a delay and runs the queued work here, with the context it already has, spending zero tokens while waiting. Also the plain timed case: 'at 9pm run X', 'in 30 minutes do X', 'queue this for later', 'run this review tonight', 'wake me at 6am and ...', 'delayed work', and queueing several jobs at set times. Not cron and not durable — Claude tasks depend on the session, Codex timers depend on a live queue receiver; not a headless or cloud run in a fresh context; not timed delivery into another cmux surface, which is cmux-cli's send-at."
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
  NOT for guaranteed schedules across receiver shutdown or machine restart. NOT for
  repeating schedules (cron, the `schedule` skill). NOT for delivering a prompt into a
  different cmux surface, which is cmux-cli's `send-at`.
argument-hint: "[--caffeinate] <when> <what to run>"
allowed-tools:
  - "Bash(date *)"
  - "Bash(TARGET=*)"
  - "Bash(caffeinate *)"
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
when it arrives. It may also carry `--caffeinate`, which explicitly opts into holding
the Mac awake until the work fires. Remove that flag before parsing the time and payload.
Caffeination is off by default; never infer consent from the delay length, an overnight
target, or the human walking away.

Codex: if that token is not substituted, take the when and the payload from the text
following the skill name in the current request.

This follows the `patient-waiting` ladder with the clock as the watched condition. That
skill owns the ladder and the hard rules; read it before arming anything.

## Three tempting wrong answers

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

## When they push for a cloud routine

"Make it a cloud routine so it survives my laptop closing" is a fair ask, and the answer
is a priced tradeoff, not a refusal. Say both halves:

- **What the cloud buys:** it fires whether or not this machine or this session is alive.
- **What it costs:** a fresh isolated session with its own checkout. Everything this
  session knows is gone unless it is inlined into the routine prompt — the pasted docs,
  the specific worries, the standing rules about what may not be published — and nobody
  is in the loop at fire time to enforce them.

If the payload's value *is* this session's context, or a human at fire time, the cloud
version is not the same job. Offer the choice; don't silently re-tool. Usually three
options: keep the watcher (accepting that a sleeping machine moves the fire to whenever
it wakes), move to a cloud routine with the context inlined, or keep the watcher as
primary and add a context-free cloud backstop. Inlining context into a cloud prompt
externalizes it — name anything internal in that list and let the human decide, rather
than pasting it on their behalf.

## Mechanism (Claude Code)

A backgrounded Bash task running a shell loop that polls the wall clock. Arm it with
`run_in_background: true`; the harness invokes the model only when the task emits its
completion line, so the wait costs zero tokens and has no 30-minute cap.

```bash
TARGET=$(date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-09 21:05:00" +%s)
while [ "$(date +%s)" -lt "$TARGET" ]; do sleep 30; done
echo "FIRE at $(date '+%-I:%M%p') — run /review-pr on https://github.com/OWNER/REPO/pull/701 now"
```

Six things there are deliberate:

1. **Epoch comparison in a loop, not one long `sleep`.** While the machine is asleep the
   whole shell loop is frozen, exactly as a single `sleep` is — no form of this wakes a
   sleeping Mac, and a target that passes during system sleep does not fire on time. What
   differs is what happens on wake: `sleep 11280` counts monotonic time, so it resumes
   with its full remaining duration still to burn and fires late by however long the
   machine was asleep, while comparing `date +%s` to a fixed target re-reads the wall
   clock and fires within one poll interval of the wake. Say that out loud whenever the
   horizon is long enough that the machine will plausibly sleep first — an overnight
   target, or any target the human is walking away from — and explain that `--caffeinate`
   is available (see *Keeping the machine awake*). Do not enable it unless requested.
2. **`date -j -f` is the BSD/macOS form.** GNU `date -d` fails here; on a GNU box it
   is the other way round, so check `uname` before pasting either.
3. **The loop exits after exactly one `echo`.** Exit ends the watch, so exactly one
   notification fires. `while true` would stay armed after firing.
4. **The emitted line is a self-contained instruction to your future self** — it names
   the skill or command and the full target (URL, path, ticket id). The notification
   arrives bare, with none of this reasoning attached, so anything the payload needs
   has to be inside the line.
5. **The task emits; it does not do the work.** A payload that is pure shell is
   tempting to run inside the loop — and then the fire is silent: no model turn
   happens, no session learns it fired, and nobody can report it or recover if
   it didn't. Put the work in the emitted line and let the woken session do it.
   Doing it in the task is defensible only when a human reads the artifact
   directly and no one needs to be told; say so when you arm it that way.
6. **Do not replace it with a long-lived `Monitor`.** Claude Code 2.1.272 accepts
   `persistent: true` but does not honor it: the task still has a 30-minute cap. A
   successful tool call therefore does not prove persistence. If the background task is
   reaped and 30 minutes or less remain, a `Monitor` can cover the remainder; otherwise
   say that no reliable in-session watcher remains and ask the human to nudge you.

## Parsing `<when>`

Resolve `<when>` to an explicit calendar timestamp before arming anything, then run one
of these to sanity-check that the target lands where you think it does and to get the
human-readable fire time you are about to quote back — each is written to start with
`date` so the `Bash(date *)` grant actually covers what gets executed.

```bash
# absolute, same day: "9:05pm" / "21:05"
date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 21:05:00" +%s
# absolute with an explicit date: "2026-09-10 09:00"
date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-10 09:00:00" +%s
# relative: "in 20 minutes" / "in 2h"
date -v+20M +%s
```

These calls are a check, not a value to paste. For Claude Code, the epoch gets computed *inside* the
background task, the way the Mechanism block does it: the inline `date -j -f`
expression re-derives the local offset at arm time, so a re-arm — or a copy of the
command into another session — can't fire against a stale number.

An absolute time already past today rolls to tomorrow — put tomorrow's explicit date in
the inline expression rather than adding 86400 to a number you carried by hand.
Say so when you do it, and say the horizon out loud: an overnight target means the
session, the machine, and the machine's wakefulness all have to survive until then. If
the human wants overnight, that is the moment to tell them this can't guarantee it.

## Keeping the machine awake

Nothing here wakes a sleeping Mac. By default, arm only the watcher and explain that a
sleeping machine delays the fire until it wakes. Hold the machine awake only when the
invocation includes the standalone `--caffeinate` flag. When present, remove the flag
from the time/payload input, arm the watcher first, then run this as a **separate
backgrounded `Bash` call**:

```bash
caffeinate -ims -t 12000
```

`-t` takes seconds: seconds-until-target plus about 600 of margin, so the assertion
outlives the fire and the payload's first minutes. `-i` blocks idle sleep, `-m` keeps the
disk from idle-sleeping, `-s` holds the system awake while on AC power.

Keep `caffeinate` out of the watcher command string. Nesting the watcher inside
`caffeinate … sh -c '…'` puts the fire line in two layers of single quotes, and payloads
carry apostrophes and quoted glob args — that is the most likely way this watcher gets
armed broken, and it fails at fire time, hours later, silently.

`caffeinate` cannot override a lid close on a MacBook: a shut lid sleeps the machine
regardless of any assertion held. Say that when you arm it — the lid has to stay open.

## Say this when you arm it (Claude Code)

- **The background task dies with the session and may be reaped on handoff.** If it is
  gone at fire time, nothing fires and there is no fallback or catch-up.
- **The background task ID**, so the human can cancel with `TaskStop`. It exists only once
  the call returns, so it goes in the message *after* arming — relay it there; never
  invent one, and never drop it because the arming message came first.
- **The exact target time and the exact payload**, in the words the notification will
  carry.

## On fire

Run the payload. **The notification is the go signal** — reporting that it arrived and
stopping is the failure mode this skill exists to prevent.

Resolve the payload's skill or command name against the skill list for the current
working directory rather than guessing it. Project skills can be exposed under a
prefixed name from a subdirectory and a bare name from the repo root, so the name that
worked when you armed the watcher is not automatically the name that works now.

## Queueing several (Claude Code)

Up to about three: one background task each. Each exits after its own fire and each
notification is unambiguous. Simplest thing that works.

More than that: one watcher holding a tab-separated `epoch<TAB>payload` schedule table,
emitting a line per due row and exiting once the last has fired. The table is the one
place literal epochs belong — the heredoc is quoted so payload apostrophes and `$` are
safe, which also means it can't re-derive a `date` expression. Read each number off the
`date` check at arm time.

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

1. **Arm first, then spend what's left.** Pause at the warning, not at exhaustion — once
   a request is actually rate limited there is no turn left to arm anything. So the
   watcher goes up while quota remains, and only the leftover margin goes to finishing
   the step in flight. If the step won't fit in that margin, stop mid-step and say which
   step and how far in; the fire line carries the resumption point either way.
2. Resolve the reset time and arm one background task whose emitted line names the resumption
   point, not just "continue":
   `FIRE — quota refilled, resume the review of https://github.com/OWNER/REPO/pull/701 at the security pass (step 3 of 5) now`.
   Back it with a `caffeinate` window only if the invocation includes `--caffeinate`.
3. Report the task ID the call returned, the exact reset time, and that the watcher dies
   with the session.
4. Spend the remaining margin on the step in flight, then stop.
5. On the notification, keep going. **No resume note is needed** — this is the same
   session and its context is still loaded. A resume note is for a pause that ends in a
   *fresh* session, which is what a context-window pause needs and this is not.

The harness can queue task-completion events while the session is rate-limited, but the
watcher itself is only as durable as its background task. Do not turn the 2026-09-10
rate-limit smoke of `Monitor` delivery into a persistence claim: later testing on
Claude Code 2.1.272 showed that `persistent: true` was accepted but ignored.

## Worked example — a queue of PR reviews

The human hands over three PRs and the times they want them reviewed, and wants the
reviews run here so they can watch and steer before anything is published.

1. Resolve each target time; confirm the review command's name for this cwd.
2. Arm one background task per PR (three is inside the one-per-job range), each emitting
   `FIRE — run /review-pr on <full URL> now`.
3. Report the three task IDs the calls returned, the three fire times, and the fact that
   all three die with the session.
4. On each notification, run the review for that URL. Don't batch it with a later one
   that hasn't fired.

## Codex — detached timer, same-thread queue

Codex CLI **0.160.1** was verified with `codex queue --thread <UUID> --message
<TEXT>`: a queued message arrived as a new user turn after the active turn's final
response, continuing the same thread with context. This is a verified version, not
an inferred minimum. Detect capability on the installed CLI before arming:

```bash
codex --version
codex queue --help
printenv CODEX_THREAD_ID
```

Require successful help showing both `--thread` and `--message`, Python 3, and the
**current** thread UUID from the active harness environment. Compare any supplied
thread ID with that live value; a handoff may name a different thread. Never use
`--last`, a session name, cwd/mtime guesses, a fork, or `codex exec/resume` as a
substitute. If current identity is unavailable or conflicts, resolve it before
arming. If queue is unavailable, report that missing capability and offer a manual
nudge or a short active-turn wait; do not claim all Codex versions require blocking.

Use a detached one-shot Python process that polls wall time and invokes queue once.
The example below is a **Codex-only** executable block. Replace the explicit ISO
calendar time (including UTC offset) and payload-file path. First use a literal
file-writing tool to save the exact payload as UTF-8 in a private file (0600),
outside git; do not embed it in Python or shell source. For a relative delay,
resolve and report its absolute target
at arm time. Do not recompute the delay when the timer fires.

```bash
python3 - <<'ARM_CODEX_TIMER'
import datetime, json, os, pathlib, shutil, subprocess, sys, tempfile, uuid
codex = shutil.which("codex")
if not codex:
    raise SystemExit("codex unavailable")
help_result = subprocess.run([codex, "queue", "--help"], capture_output=True, text=True)
if help_result.returncode or not all(x in help_result.stdout for x in ("--thread", "--message")):
    raise SystemExit("installed codex lacks queue capability")
thread = os.environ.get("CODEX_THREAD_ID", "")
uuid.UUID(thread)  # fail closed on missing/malformed current identity
when = datetime.datetime.fromisoformat("2026-10-07T21:05:00-04:00")
if when.tzinfo is None or when.timestamp() <= datetime.datetime.now().timestamp():
    raise SystemExit("resolve a future target with an explicit timezone first")
payload = pathlib.Path("/absolute/path/to/private-payload.txt").read_bytes().decode("utf-8")
os.umask(0o077)
job = pathlib.Path(tempfile.mkdtemp(prefix="codex-until-"))
(job / "job.json").write_text(json.dumps({"codex": codex, "thread": thread,
    "target": when.timestamp(), "payload": payload}), encoding="utf-8")
runner = job / "timer.py"
runner.write_text(r'''
import datetime, json, pathlib, signal, subprocess, sys, time
job = pathlib.Path(sys.argv[1])
config = json.loads((job / "job.json").read_text(encoding="utf-8"))
def status(value):
    (job / "status").write_text(value + "\n", encoding="utf-8")
    print(datetime.datetime.now(datetime.timezone.utc).isoformat(), value, flush=True)
def cancel(signum, frame):
    status("cancelled")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, cancel)
status("armed")
while True:
    if (job / "cancel").exists():
        status("cancelled")
        raise SystemExit(0)
    remaining = config["target"] - time.time()
    if remaining <= 0:
        break
    time.sleep(min(1.0, remaining))
if (job / "cancel").exists():
    status("cancelled")
    raise SystemExit(0)
status("enqueue_started")
try:
    result = subprocess.run([config["codex"], "queue", "--thread", config["thread"],
        "--message", config["payload"]], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, timeout=60)
    status("enqueued" if result.returncode == 0 else "enqueue_failed rc=" + str(result.returncode))
except subprocess.TimeoutExpired:
    status("enqueue_timeout outcome_unknown")
except OSError as error:
    status("enqueue_failed " + type(error).__name__)
''', encoding="utf-8")
with (job / "timer.log").open("ab") as log:
    process = subprocess.Popen([sys.executable, str(runner), str(job)],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        start_new_session=True, close_fds=True)
(job / "pid").write_text(str(process.pid) + "\n", encoding="utf-8")
print(json.dumps({"job": str(job), "pid": process.pid, "thread": thread,
    "target": when.isoformat()}))
ARM_CODEX_TIMER
```

Payload storage is private (directory 0700, files 0600); keep it out of git and
credentials. Reading the literal UTF-8 file as bytes and storing it in JSON preserve
backslashes, quotes, dollars, backticks and line endings without shell evaluation
or Python string-escape decoding. `subprocess` uses an argument list,
never `shell=True`. This CLI exposes only `--message`, so the payload is briefly
visible in the queue process's argv and subject to OS argument-size limits; keep it
small and do not put secrets in it. Logs record state, not payload or CLI output.

After launch, read the job's `status` and confirm `armed` (or a terminal state for a
very short delay); spawning a PID alone is not proof of successful arming. Report the
job directory, PID, exact UUID, timezone-qualified deadline, exact payload, and log
path. End the turn: no agent polling, blocked exec cell, or model tokens while waiting.
A busy thread may receive the turn only after its current response finishes.

**Cancellation:** create `cancel` in this exact job directory; the timer records
`cancelled` within a poll interval. Do not kill a saved PID blindly: PIDs are reused.
If immediate termination is necessary, first confirm the live command belongs to
this job, then send SIGTERM. Cancellation racing `enqueue_started` may be too late;
a message already accepted cannot be recalled by stopping the timer. Inspect `status`
and `timer.log`; do not retry an ambiguous timeout automatically. Once terminal,
remove only this job's files when no longer needed. Never cancel unrelated timers.

**Limits:** detachment releases the agent turn and can outlive that turn, but is not
reboot persistence or a delivery guarantee. The process can be reaped; machine sleep
freezes it, then it checks wall time on wake and attempts one late enqueue. It does
not wake the machine. Queue needs the appropriate live Codex daemon/app-server,
account/config/endpoint and existing thread available at fire time. Preserve the
launch environment and, if a remote receiver is in use, verify and supply its exact
queue connection options without copying credentials into the job. Do not assume
queue success when the receiver is closed, disconnected or restarted; shutdown,
reconnect, quota reset and overnight delivery require separate evidence.

`--caffeinate` remains explicit opt-in only. On macOS launch a separate detached
`caffeinate -ims -t <seconds-until-target+600>` process with closed stdin and file or
null output; report its PID and cancel it separately after verifying its identity.
It does not override a closed lid or guarantee receiver availability. Without the
flag, arm only the timer.

**Evidence:** `enqueued` means the command returned zero, not that the new user turn
was delivered or the payload ran. Verify delivery from the receiving thread with a
unique harmless nonce in a short delayed smoke, then execute the queued instruction
on arrival. Report that observed case separately from future reliability. For multiple
jobs use one private timer directory per job and space heavy work apart; do not turn
the Claude schedule-table example into a shell payload launcher for Codex.
