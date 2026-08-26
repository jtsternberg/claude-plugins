---
name: send-at
description: "Wait until a target time within THIS live cmux-resident agent session, then deliver a prompt into one exact cmux surface (by UUID) and do a basic read-screen check. For 'send this at 3pm', 'in 30 minutes send X to surface <uuid>', 'schedule a prompt into that cmux surface', deferred/timed keystroke or prompt delivery into a specific cmux tab. Same-session best-effort timer, not a durable cron — it fires only while this session and the Mac stay alive."
when_to_use: |
  Use when the user wants a prompt (or command) delivered into a SPECIFIC existing cmux
  surface at a later time, and they can give the exact surface UUID. Triggers: "at 3pm send
  … to surface <uuid>", "in 20 minutes paste this into that tab", "wake up later and send X
  into the cmux surface I'm pointing at". NOT for cross-workspace agent calls with delivery
  verification (that is hotline's dial), and NOT for durable scheduling that must survive the
  session closing (impossible here — see the reliability envelope below).
argument-hint: "<when> <surface-uuid> <prompt>"
allowed-tools:
  - "Bash(cmux *)"
  - "Bash(which cmux)"
  - "Bash(jq *)"
  - "Bash(date *)"
  - "Bash(*/scripts/*)"
---

# send-at — timed prompt delivery into one exact cmux surface

Deliver a prompt into a **specific existing cmux surface**, identified by its UUID, at a
target time — while this agent session stays alive. The surface UUID is the whole address:
no prior hotline connection, no cached session, no discovery. This skill does the *when*
(a harness-native in-session wait) and hands the *what/where* to a deterministic delivery
script.

## Read this first — the honest reliability envelope

This is a **same-session, best-effort timer, not a durable scheduler.** It fires the delivery
only if **this agent process and the Mac are still alive at the target time.** That boundary
is not a limitation to fix later — it is forced by two hard constraints working together:

- **The delivery must run from a process with cmux ancestry.** cmux's socket defaults to
  `cmuxOnly`: only processes cmux itself spawned may drive it. The agent's own shell (Claude's
  Bash tool / Codex's exec cell) has that ancestry; a `launchd`/`cron` job or a cloud routine
  does **not** — cmux refuses them. So the thing that fires the send has to be *this* agent,
  in *this* pane.
- **Nothing that outlives this process can wake this process in-pane.** An external timer
  (launchd/cron) has no cmux ancestry, and a cloud-scheduled agent runs off-machine with no
  socket at all. Both are excluded. So the only clock we can use is one that keeps *this*
  session waiting.

**Consequences to state plainly to the user before scheduling anything far out:**

- Short horizons (seconds to ~1 hour, up to a few hours if the Mac stays awake) are the honest
  sweet spot. An "at 9am tomorrow" ask cannot be made reliable here — say so and point at a
  durable OS/cloud scheduler if they truly need overnight delivery (accepting it then can't
  target a cmux surface for the ancestry reason above).
- If the session is closed, the agent is interrupted, or the Mac sleeps through the target,
  **nothing fires.** There is no catch-up.
- Delivery itself is **best-effort**, not verified (V1 has no nonce/transcript check). `cmux
  send` can sporadically fragment or drop bytes (not size-gated), a busy REPL silently
  enqueues the message, and a user-scrolled viewport hides it. The read-screen check is
  therefore **informational** — "not observed" is never proof the send failed.

If any of that makes the ask a no-go, stop and say so rather than scheduling theater.

## The contract (do not break these)

1. **Exact surface only.** Deliver to the UUID given, resolved from **one** `cmux tree
   --all --json` snapshot taken at fire time. Recover its workspace UUID only as targeting
   context for the send.
2. **No fallback, ever.** If the UUID is gone from that snapshot, or the send fails — **report
   and stop.** Never create another surface, resolve to a different destination, resume
   elsewhere, fork a session, or retry. The delivery script enforces this; do not work around
   it.
3. **Wake this session, never an external process.** The wait must keep or resume *this*
   cmux-resident turn. Never schedule the delivery through `launchd`, `cron`, `at`, a cloud
   routine, or any process lacking cmux ancestry.

## Step 1 — Parse the request

You need three things:

- **`<when>`** — an absolute time ("3:00pm", "15:00") or a relative one ("in 20 minutes").
  Convert it to an epoch-seconds target and to a delay in seconds from now:
  ```bash
  now=$(date +%s)
  target=$(date -j -f "%H:%M" "15:00" +%s 2>/dev/null)   # absolute (macOS date)
  # or, relative: target=$(( now + 20*60 ))
  delay=$(( target - now ))
  ```
  If `delay` is negative (time already passed today) or larger than a few hours, surface that
  to the user — the second case bumps against the reliability envelope above.
- **`<surface-uuid>`** — the exact cmux surface UUID. If the user gives a ref (`surface:17`)
  or a name instead, resolve it to a UUID **now** with `cmux tree --all --json --id-format
  both` (or the `using-cmux-cli` skill's `find-surface.sh`) and confirm it with the user — the
  UUID is what survives; refs renumber.
- **`<prompt>`** — the text to deliver. Single-line is the V1 sweet spot; embedded
  newlines/backslash-escapes are not byte-exact (V1 has no paste transport) — warn if the
  prompt contains them.

## Step 2 — Wait inside this session (harness-native)

Pick the wait that matches your harness. Both keep *this* process alive and cmux-resident;
neither hands off to an external timer.

### Claude Code — wake-from-background (preferred)

Run a background until-clock loop with the **Bash tool's `run_in_background`**. It exits the
moment the target time arrives and re-invokes *this same session* — so the process (and its
cmux ancestry) is intact when you deliver, and the session is free in the meantime.

```bash
# run_in_background: true — a single wake when the clock reaches $target
until [ "$(date +%s)" -ge "$target" ]; do sleep 20; done
```

When it completes and you're re-invoked, go straight to Step 3.

- Do **not** use the `schedule` skill / cloud routines / `CronCreate` — those run off-machine
  with no cmux socket.
- `ScheduleWakeup` (clamped to ≤1h per hop) and `Monitor` (≤1h `timeout_ms`) also keep this
  session, but the background until-loop has no such cap and is simpler. Reach for them only
  if you're already inside a `/loop`.

### Codex (0.149.1) — blocking active-turn wait

Codex has **no wake-from-idle** primitive that resumes in-pane. Its only in-session wait is
`functions.wait` on a yielded exec cell — a **blocking** wait that occupies the turn until the
cell finishes. Yield a blocking until-clock exec cell and wait on it:

```bash
until [ "$(date +%s)" -ge "$target" ]; do sleep 20; done
```

Because this blocks the whole turn, keep Codex horizons short — a multi-hour block strains
exec-cell limits and ties up the session. `current_time_reminder` only injects the current
time into context; it is **not** an after-turn scheduler. A "persistent goal" is not a timer
either. Do not lean on either as a clock.

## Step 3 — Deliver (fire time)

Run the bundled delivery script. Under Claude Code the `${CLAUDE_SKILL_DIR}` token resolves
mechanically to this skill's directory.

Codex: this path resolves under Claude Code; substitute the directory containing this
`SKILL.md`.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/send-to-surface.sh" --surface "<surface-uuid>" --prompt-file "<path>"
```

**Prefer `--prompt-file`** — it keeps the payload off the process argument list, which is
`ps`-visible to any local user. Write the prompt to a temp file and pass its path. `--prompt
"<text>"` is a convenience for quick, non-sensitive sends and is fine there.

The script takes one `cmux tree` snapshot, resolves the UUID → workspace, `cmux send`s the
text, settles briefly, then submits with a **separate** `cmux send-key Enter` (a newline bundled
into the text would not submit into a TUI/Ink REPL), then does the informational read-screen
check. It prints a single status word on stdout and exits with a matching code.

## Step 4 — Report the real outcome

Read the status word (and exit code) and tell the user the truth:

| stdout / exit | Meaning | What to say |
|---|---|---|
| `sent delivery_observed=true` (0) | text + Enter delivered, and seen on screen | Delivered. |
| `sent delivery_observed=false` (0) | text + Enter delivered, not seen on screen | Delivered — but the on-screen check didn't see it, which a busy or scrolled REPL can cause, so it's not proof either way. |
| `surface_gone` (3) | UUID absent at fire time (or cmux unreachable) | The target surface no longer exists; **nothing was sent** and no fallback was attempted. |
| `send_failed` (4) | `cmux send` failed | The send failed; the Enter was deliberately not sent. Do not re-send. |
| `enter_failed` (5) | text sent, Enter failed | The text may be sitting unsubmitted in the input box. Report it; do not re-send. |
| `error` (2) | bad args / cmux or jq missing | Report and stop. |

Never upgrade a false `delivery_observed` into a claim of failure, and never silently re-send.

## What V1 deliberately is not

No hotline dependency, no delivery nonces, no transcript inspection, no byte-exact paste
transport, no elaborate REPL-state detection, no retries, and no recovery system. If a caller
needs *verified* cross-workspace delivery, that is the `hotline` plugin's `dial` skill, not
this.
