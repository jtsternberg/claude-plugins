---
name: runway
description: Track how much runway a Claude Code session has left - subscription quota (5-hour and weekly limits) and context window usage - then decide whether to keep going or, when the context is full, hand off to a fresh session. A quota limit never stops work early: keep working until a request is actually rate limited (HTTP 429), with the delayed-work:until wake-up already armed for the reset, then go idle. Use when a session-start or prompt hook prints a `runway [notice|wrap_up|stop]` line, when the user asks about rate limits, quota, usage, tokens left, context window, "how much room is left", "will this fit", or "am I about to get cut off", before starting any long or multi-step task, and when a request is rate limited with HTTP 429. Also use to finish setting the skill up, meaning installing, enabling, disabling, or removing its session hooks, or checking whether they are wired.
---

# Runway

Two budgets end a session: the subscription quota (5-hour window, plus weekly buckets) and the
context window. Both are readable. Read them instead of guessing, so a limit lands on a plan
rather than mid-edit.

Claude Code only: Codex has no session hooks and no quota transcript for the script to read.

## Read the numbers

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/runway.py"            # full report + verdict
python3 "$SKILL_DIR/scripts/runway.py" --brief    # one line, what the hooks print
python3 "$SKILL_DIR/scripts/runway.py" --json     # raw figures for exact math
```

The script needs no arguments: it picks up the session from `$CLAUDE_CODE_SESSION_ID` and the
project from the working directory. Quota comes from the same endpoint `/usage` uses; context
comes from the token counts on the last assistant message in the session transcript.

Run it when:

- a hook line says `notice`, `wrap_up`, or `stop`
- about to start work spanning many turns (a refactor, a test suite, a review pass)
- a request just failed with HTTP 429
- the user asks anything about limits, usage, or remaining room

## Act on the verdict

The script reports a level per budget and an overall worst-case. Thresholds are percent used:
notice 80 / wrap_up 90 / stop 95 for context, notice 90 / wrap_up 95 / stop 98 for quota.

| Level | Context window | Quota |
| --- | --- | --- |
| `ok` | keep working, say nothing | keep working, say nothing |
| `notice` | mention it once, prefer subagents for wide searches, stop re-reading whole files | keep working, mention the reset time once |
| `wrap_up` | finish the step in flight, no new files opened, then hand off | keep working; arm the `until` wake-up once |
| `stop` | finish the step, then hand off to a fresh session | keep working; arm the `until` wake-up once |

Quota levels are informational by default. The `runway ACTION` line says to keep working and
carries the exact wake time to hand `until` now, so the wake is armed before any 429 lands. Set
`RUNWAY_STOP_WORK=1` (any value other than empty, `0`, `false`, `no`) to get the stricter
behavior instead: quota `wrap_up` and `stop` pause the task until the reset, with a `CronCreate`
restart in this same session (see *Pausing with RUNWAY_STOP_WORK*).

Mention a level once. Repeating the same warning every turn burns the very budget being
protected.

## Working to the 429 (default)

Keep working through every quota level. Do not wind down or refuse new tasks because a quota
figure is high. The limit itself is the signal.

A rate-limited request has no turn left to arm anything, so the wake-up goes up *before* the
limit, while quota remains. At quota `wrap_up` or `stop`, once per reset window:

1. Take the wake time from the `runway ACTION` line (two minutes past the reset), or `wake_at` on
   the session bucket in `${CLAUDE_SKILL_DIR}/scripts/runway.py --json` (Codex: substitute the
   directory containing this SKILL.md).
2. Invoke `delayed-work:until` for that time with a self-contained payload: the task, its exact
   resume point, and "if the work is already finished, say so in one line and stop". It fires in
   this same session with the context still loaded.
3. Run the `--armed` command the `runway ACTION` line prints, as printed: it carries the script's
   absolute path, the quoted wake time, and `--bucket <label>`. The hooks then report that bucket's
   wake as armed, and stop asking you to invoke this skill on every prompt.
4. Say the wake time and task id to the user in two lines, including that the watcher dies with
   the session. Then carry on with the work.

When a request is finally 429ed, stop and wait for the wake line. If the wake was never armed
(hooks off, or the limit landed between checks), arm it now if a turn remains, taking the reset
time from the message Claude Code printed with the limit.

A weekly bucket's reset can be days away, so its `runway ACTION` line offers two commands. If
the user wants the session to sit that long, arm `until` and run the `--armed` command. Otherwise
run the `--ack` command it prints, say when the bucket resets, and carry on. Either one records
the bucket for this session, so the hooks stop asking about it until that reset passes; a new
reset window asks once more.

## Pausing with RUNWAY_STOP_WORK

With `RUNWAY_STOP_WORK` set, a tight quota pauses the task on purpose. At `stop`, or at `wrap_up`
when the remaining work clearly needs more turns than the budget allows:

1. Finish or cleanly abandon the edit in flight. Never leave a file half-written.
2. Stop starting new work.
3. Schedule the restart in this session rather than asking the user to remember. The action line
   carries a ready-made cron expression for two minutes past the reset:

   ```
   CronCreate  cron: "<the expression from the action line>"  recurring: false
               prompt: runway: quota has reset, carry on with the task you paused
   ```

   The restart lands in this same session, context intact, so it needs nothing written down.
4. Tell the user in two lines: why the pause, and the clock time it resumes. A reset is a refill,
   not a deadline: quota at 96% resetting in 5 minutes means wait 5 minutes, not stop for the day.

Say that the session must stay open, because a `CronCreate` job lives in session memory and dies
with the session. If the user would rather close it, skip the cron, give them the clock time, and
tell them `claude --resume` brings this session back with its context.

## When the context window fills

Waiting changes nothing here, and neither `until` nor a cron can help, because the fix is a fresh
context. At context `wrap_up` or `stop`, finish the step in flight, then hand off to a fresh
session: use the `handoff` skill when it is installed, otherwise leave the user a brief summary in
chat to start the new session from. Say that instead of "come back later".

Do not commit, stash, or revert anything as part of pausing or handing off unless the user asks.

## Reading the numbers honestly

- The context figure comes from the previous assistant turn, because the transcript is written
  after a turn ends. It lags by whatever the current turn has added - treat it as a floor.
- The context window size comes from the model, and the only place the resolved model id appears
  is the hook payload on stdin: `SessionStart` carries `model`, `PostModelSwitch` carries
  `to_model`. The script caches it per session in `~/.claude/runway/state.json`, so later runs
  know the window even though the transcript records the plain API id without its `[1m]` marker.
  Order of precedence: `--limit`, `RUNWAY_CONTEXT_LIMIT`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, the
  model from the hook payload or the cache, the transcript's id, the `model` setting, then 1M. A
  200k family such as Haiku is recognised by name; anything unknown is treated as 1M.
- A session started before the hooks were wired has nothing cached, so its window is a guess
  until the next `/model` switch or restart.
- A brand-new session shows no context figure at startup, because it has no reply to measure
  yet, and the hook prints no warning about it. It never borrows the figure from another
  session's transcript.
- A model-scoped bucket (such as `weekly_scoped:Fable`) counts only when the session runs that
  model. The API's `is_active` flag does not track this, so runway matches the bucket's model
  name against the session's model id: "Opus 5" matches `claude-opus-5` and `claude-opus-5[1m]`
  but not `claude-opus-5-5`, and "Opus" matches every Opus. The model comes from the hook payload,
  then the cached model, then the transcript id; with none of those, the bucket's `is_active`
  flag decides. A bucket with no model scope always counts, whatever `is_active` says. Buckets
  marked `(<model> only - not this session)` and `runway IGNORE:` lines do not apply to this
  session. Keep working; never stop or pause because of them.
- Override any threshold with `RUNWAY_CONTEXT_WRAP_UP`, `RUNWAY_QUOTA_STOP`, and the rest of the
  `RUNWAY_<SUBJECT>_<LEVEL>` family, or `RUNWAY_RESET_SOON_MINUTES` for the refill-is-close
  window (stop-work mode only). `RUNWAY_STOP_WORK` switches quota levels from informational to
  pausing.
- No token can be read without the OAuth credentials Claude Code stores locally. When the script
  reports a `401`, the fix is re-running `claude` to refresh - not a code change.

## Finishing the install

Installed as a plugin, the hooks come with it (`hooks/hooks.json`) and there is nothing to run.
They load at startup, so they fire once Claude Code restarts after the install.

A standalone copy of the skill (a folder under `~/.claude/skills/`) has no `hooks.json`, so its
hooks are wired once with the installer. The script also wires them itself: in a standalone copy,
any run without `--brief` checks the settings file and wires the hooks when they are missing or
out of date, printing `runway: hooks were missing, wired them` on stderr. Repeat that line to the
user when it appears, since nothing fires until Claude Code restarts. Inside the plugin it never
does this. Use `--no-self-install` to read the numbers without touching any settings.

Each hook command the installer writes runs through `python3` and carries `--hooks-version N`.
When the hook commands change, the number goes up, and in a standalone copy the session-start
hook prints a line like this until someone re-runs the installer:

```
runway SETUP: hooks need installing (PostModelSwitch: missing). Run `python3 ".../install-hooks.py"`, ...
```

When you see `runway SETUP:`:

1. Run the command it names, through `python3` as printed, because a copied skill can lose its
   execute bit.
2. If the command is denied, or fails with a permission error (the settings file is protected,
   or the sandbox blocks the write), do not try workarounds. Ask the user to type the same
   command with a `!` in front, for example `! python3 ".../install-hooks.py"`, so it runs in
   their own shell.
3. Tell the user to restart Claude Code. New hooks do not load until then.

The same rule applies when a hook error mentions `Permission denied` on `runway.py`: that hook
runs the script without `python3`, and the installer rewrites it. Inside the plugin the
`runway SETUP:` line never appears, because `hooks/hooks.json` is the install and the settings
file owes it nothing.

To install or check explicitly:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/install-hooks.py" --check      # exit 1 and a list of problems when not current
python3 "$SKILL_DIR/scripts/install-hooks.py"              # wire or repair it (standalone copy only)
```

Inside the plugin, `--check` reports that the hooks ship with the plugin and names any runway
entries still in the settings file, and a plain install refuses, because settings-file entries
next to the plugin's would run every hook twice. Runway hooks wired by a standalone copy keep running after the plugin is
installed: remove them with `install-hooks.py --uninstall`, which strips every settings-file hook
whose command names `runway.py` and leaves the plugin's hooks and all other hooks alone.

For a standalone copy, the installer merges three hooks into `~/.claude/settings.json`, pointing
at `runway.py` wherever this skill sits: `SessionStart` for the opening snapshot, a throttled
`UserPromptSubmit` for the periodic re-check, and a silent `PostModelSwitch --record-model` that
keeps the cached model right after a `/model` change. It leaves every other hook in that file
alone, replaces its own entries instead of duplicating them on a re-run, and backs the file up
before it writes.

Variants: `--no-prompt-hook` for `SessionStart` and `PostModelSwitch` without the prompt
re-check, `--dry-run` to show the
resulting block without writing, `--uninstall` to remove every runway hook, `--settings PATH` to
target a project's `.claude/settings.json` instead of the user's.

Never hand-edit the settings JSON for this. A bad merge silently disables the user's other hooks,
which is exactly what the installer exists to prevent.

After changing either script, run the suite:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 -m unittest discover -s "$SKILL_DIR/tests"
```
