---
name: caffeinate
description: Keep a Mac awake while long-running Claude Code agents, builds, or commands run, using macOS's built-in `caffeinate`. Triggers on "keep mac awake", "don't sleep", "stay awake", "caffeinate", "overnight run", "long-running agent", "running while afk", "leave this running", or any setup where the user is about to start a task expected to outlast the lid being closed or the display sleeping. macOS-only — explains and exits on Linux.
---

# caffeinate — keep the Mac awake

macOS ships `caffeinate`. Use it. No daemons, no apps, no half-open laptops in airports.

## Platform check

If `uname` is not `Darwin`, say so and stop:

> Not macOS — `caffeinate` is a macOS-only tool. On Linux, use `systemd-inhibit`, `caffeine`, or `xset s off -dpms` depending on environment.

## The three patterns

Pick based on what the user is doing.

### 1. Tie wakefulness to a running process (preferred)

When there's already a PID — a running `claude` session, build, sync, agent loop:

```bash
caffeinate -i -w <PID> &
```

- `-i` prevents idle sleep
- `-w <PID>` exits caffeinate when that PID exits
- `&` backgrounds it so the shell stays usable

Find the PID with `pgrep -f claude` or `echo $$` from inside the long-running shell.

### 2. Wrap a command

When launching the long task fresh:

```bash
caffeinate -i <command and args>
```

`caffeinate` exits the moment the wrapped command exits. Cleanest pattern — no orphan processes, no manual cleanup.

### 3. Time-bounded, full lockout (overnight runs, lid closed)

```bash
caffeinate -dimsu -t 28800   # 8 hours
```

- `-d` display sleep
- `-i` idle sleep
- `-m` disk sleep
- `-s` system sleep (only effective on AC power)
- `-u` declares user activity (resets idle timer for 5s, useful as a one-shot nudge)
- `-t <seconds>` auto-expire so it can't run forever

Use `-s` only when plugged in. On battery, drop it: `caffeinate -dim -t <seconds>`.

## Lid-closed (clamshell) caveat

`caffeinate` alone does **not** keep a MacBook awake with the lid shut on battery. For true clamshell-while-unplugged you need external power + display + input, or a tool like `InsomniaX`/`Amphetamine`. Tell the user this if they ask about closing the lid.

## Picking the flag set

| Goal | Flags |
|---|---|
| Just stop idle sleep during a task | `-i` |
| Also keep the display on (watching output) | `-di` |
| Long unattended run, plugged in | `-dimsu -t <sec>` |
| Tied to a specific PID | add `-w <PID>` |

`man caffeinate` has the full list. Don't invent flags.

## What to do for the user

1. Confirm macOS (`uname` → `Darwin`).
2. Ask (or infer) whether there's a PID to attach to, a command to wrap, or just a time window.
3. Build the exact one-liner from the patterns above. Show it. Run it if they want, otherwise hand it over.
4. Mention how to stop it: `kill %1` for backgrounded `&`, or it self-exits when the PID/command/timer ends.

Keep it tight. One command, one line of explanation.
