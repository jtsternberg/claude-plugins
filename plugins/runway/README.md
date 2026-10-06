# runway

Know how much session you have left before Claude Code tells you the hard way.

Two budgets end a Claude Code session: the subscription quota (the 5-hour window, plus weekly
buckets) and the context window. Neither is visible while you work. You find out about the first
one when a request fails with HTTP 429 halfway through an edit, and about the second when a
compaction eats the plan you were following.

`runway` reads both on every session start and decides what to do about it: stay quiet, warn once,
or, near a quota limit, keep working with a wake-up armed for the reset so the same session carries
on after it.

## What it does

- Reads the 5-hour and weekly quota buckets from the same endpoint the `/usage` command uses.
- Reads context usage from the session transcript and sizes it against the model you are on, so a
  1M window does not read as a nearly full 200k one.
- Grades each budget `ok` / `notice` / `wrap_up` / `stop` against thresholds you can change.
- Keeps working through every quota level. At quota `wrap_up`/`stop` it has Claude arm the
  `delayed-work:until` watcher once, for two minutes past the reset, and carry on. A rate-limited
  request has no turn left to arm anything, so the wake goes up first. When the 429 lands the
  session idles, then wakes at the reset with its context intact. Needs the `delayed-work` plugin.
- A weekly bucket's reset can be days away, so there Claude either arms the wake (when you want
  the session to wait that long) or acknowledges the bucket with `--ack` and carries on. Either
  one quiets the hooks for that bucket until its reset passes.
- Set `RUNWAY_STOP_WORK=1` for the stricter behavior: at a quota `wrap_up` or `stop`, Claude
  finishes the step, stops starting new work, and schedules a `CronCreate` restart in the same
  session for just after the reset. The session must stay open for that, since the job lives in
  session memory.
- A full context window cannot be waited out. Claude finishes the step and hands off to a fresh
  session, through the `handoff` skill when it is installed or a brief summary in chat otherwise.
- Says nothing while everything is fine. A throttled prompt hook skips the network call entirely
  as long as the last check was clean.

## Install

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install runway@jtsternberg
claude plugin install delayed-work@jtsternberg   # the wake-up at the reset
```

Restart Claude Code, because hooks load at startup. That is the whole install: the plugin ships
its hooks in `hooks/hooks.json`, so there is no installer to run.

Claude Code only. Codex has no session hooks and no quota transcript for the script to read.

The skill still answers on demand without any hooks. They are what makes the check automatic
instead of something you have to remember to ask for.

### What the hooks do

| Event | Command | Why |
| --- | --- | --- |
| `SessionStart` | `runway.py --brief` | opening snapshot |
| `UserPromptSubmit` | `runway.py --brief --throttle 900` | periodic re-check |
| `PostModelSwitch` | `runway.py --record-model` | prints nothing; records the model you switched to, which tells the script whether the window is 200k or 1M |

The prompt hook re-checks at most every 15 minutes while things are clean, and on every prompt
once a budget is tight. Once every tight quota bucket has its wake-up armed or acknowledged, it
goes back to the 15-minute pace and stops asking Claude to invoke the skill each prompt.

### Standalone skill copy

Copying `skills/runway/` into your skills folder instead of installing the plugin gives you the
files without `hooks/hooks.json`. Wire the hooks once with the bundled installer, run from that
copy:

```bash
python3 <skill-dir>/scripts/install-hooks.py                 # wire all three hooks
python3 <skill-dir>/scripts/install-hooks.py --check         # is it current?
python3 <skill-dir>/scripts/install-hooks.py --dry-run       # show the JSON, write nothing
python3 <skill-dir>/scripts/install-hooks.py --no-prompt-hook   # skip the prompt re-check
python3 <skill-dir>/scripts/install-hooks.py --uninstall     # remove every runway hook
python3 <skill-dir>/scripts/install-hooks.py --settings ./.claude/settings.json  # per project
```

`<skill-dir>` is wherever you put the copy. The installer merges the three entries above into
`~/.claude/settings.json`, pointing at `runway.py` in that copy, and leaves every other hook
alone. Re-running it replaces the runway entries instead of duplicating them, and it copies the
settings file to `settings.json.bak-<timestamp>` before writing. The commands it writes run
through `python3`, so they keep working when a copy loses the execute bit.

Forgetting the installer is recoverable: in a standalone copy, any run of `runway.py` without
`--brief` notices the hooks are missing or out of date and wires them itself, so asking the skill
anything installs it. Pass `--no-self-install` to suppress it. Inside the plugin this never
happens, and the installer refuses to install there, since the plugin's own hooks already run.

#### Updating and repairing a standalone copy

Every hook command the installer writes carries `--hooks-version N`. An update that changes the
hooks raises that number, so an install from an older copy shows up as out of date. Three things
check it:

- `install-hooks.py --check` lists each problem, such as `PostModelSwitch: missing` or
  `SessionStart: out of date`, and exits 1. It exits 0 only when every required hook is present
  and current. `UserPromptSubmit` is optional, so `--no-prompt-hook` installs still pass.
- The session-start hook prints a `runway SETUP:` line while the install is incomplete. The line
  names the exact installer command to run.
- A manual run of `runway.py` repairs the install by itself.

The repair process after any update:

1. Run `python3 <skill-dir>/scripts/install-hooks.py`. Claude can do this when it sees the
   `runway SETUP:` line.
2. If Claude is not allowed to run it, or it fails with a permission error, run it yourself by
   typing `! python3 <skill-dir>/scripts/install-hooks.py` in the Claude Code prompt. The skill
   tells Claude to ask you for this instead of looking for a workaround.
3. Restart Claude Code.
4. Confirm with `python3 <skill-dir>/scripts/install-hooks.py --check`.

A hook failing with `Permission denied` on `runway.py` runs the script without `python3`. The
same repair process rewrites it.

The plugin install needs none of this: its hooks ship in `hooks/hooks.json`, so the session-start
hook never prints a `runway SETUP:` line there.

### Moving from a standalone copy to the plugin

Remove the standalone copy's hooks, or every runway hook runs twice. Its installer's
`--uninstall` strips every hook in `~/.claude/settings.json` whose command names `runway.py`,
whichever copy wrote it, and leaves other hooks alone. With the standalone copy already deleted,
run the plugin's copy instead; it edits only the settings file, so the plugin's own hooks stay:

```bash
python3 <skill-dir>/scripts/install-hooks.py --uninstall
```

Inside the plugin, `install-hooks.py --check` names any runway entries still in the settings
file.

## Use it

```bash
python3 <skill-dir>/scripts/runway.py            # full report
python3 <skill-dir>/scripts/runway.py --brief    # the hook line
python3 <skill-dir>/scripts/runway.py --json     # raw figures
python3 <skill-dir>/scripts/runway.py --limit 200000   # force a window size
```

`<skill-dir>` is `skills/runway` inside the installed plugin, or your standalone copy. In a
session you rarely need the path: ask the skill, and Claude runs the script from where it lives.

The remaining flags are there for the hooks and the skill rather than for you:

- `--record-model` records the model and exits without printing anything.
- `--armed "<YYYY-MM-DD HH:MM>" --bucket <label>` records that the session armed its wake-up for
  that bucket. The action line prints the exact command, absolute path included.
- `--ack ["<YYYY-MM-DD HH:MM>"] --bucket <label>` records that the session carries on without a
  wake-up for that bucket. Without a time it uses the bucket's wake from the last check.
- `--no-self-install` stops a run from wiring missing hooks. The self-install notice goes to
  stderr, so `--json` still parses on the run that installs.
- `--hooks-version N` is written into hook commands by the installer, so an outdated standalone
  install can be told apart from a current one.

An armed or acknowledged bucket stays quiet until its recorded wake time passes, so a reset time
that drifts by a minute between checks does not re-ask.

```
Quota (enterprise / default_claude_max_5x)
  session                [#############-----------]  56.0%  resets 22:40 (in 2h 16m)
  weekly_scoped:Fable    [##----------------------]  10.0%  resets 21:00 (in 144h 36m)  (Fable only - not this session)

Context window (claude-opus-5[1m])
  used                   [##----------------------]   8.2%  81,865 / 1,000,000
  free 918,135 tokens   cache-read 75,446, cache-write 6,417, fresh input 2
  session 11991bbf-5962-4e6e-a1ad-00ca83545494

Verdict: ok
```

In conversation, just ask: "how much runway is left?", or "am I about to get rate limited?".

## Thresholds

Percent used. The defaults fire late on purpose, so the skill keeps quiet until things are
actually tight.

| Budget | notice | wrap_up | stop |
| --- | --- | --- | --- |
| Context window | 80 | 90 | 95 |
| Quota bucket | 90 | 95 | 98 |

Override any level with an environment variable, either in the `env` block of
`~/.claude/settings.json` or in your shell:

```
RUNWAY_CONTEXT_NOTICE   RUNWAY_CONTEXT_WRAP_UP   RUNWAY_CONTEXT_STOP
RUNWAY_QUOTA_NOTICE     RUNWAY_QUOTA_WRAP_UP     RUNWAY_QUOTA_STOP
RUNWAY_RESET_SOON_MINUTES   # refill-is-close window, default 10
RUNWAY_CONTEXT_LIMIT        # context window size, when the model guess is wrong
RUNWAY_STOP_WORK            # set to pause until the reset at quota wrap_up/stop instead of working to the 429
```

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is read too, since Claude Code's own override should not have to
be repeated here. `RUNWAY_CONTEXT_LIMIT` wins when both are set.

## How it reads the numbers

Quota comes from `GET https://api.anthropic.com/api/oauth/usage`, authorised with the OAuth token
Claude Code already stores: the macOS Keychain item `Claude Code-credentials`, or
`~/.claude/.credentials.json` on other platforms. The script only reads, and sends nothing
anywhere else.

Context comes from the `usage` block on the newest assistant message in
`~/.claude/projects/<slug>/<session-id>.jsonl`. Input plus cache-read plus cache-write tokens is
the context the model just saw.

The window size comes from the model. The resolved model id, the one carrying a `[1m]` marker,
reaches the script only through the hook payload on stdin: `model` on `SessionStart`, `to_model`
on `PostModelSwitch`. It is cached per session in `~/.claude/runway/state.json`, because the
transcript records the plain API id without that marker. The script takes the first answer it can
get, in this order: `--limit`, `RUNWAY_CONTEXT_LIMIT`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, the model
from the hook payload or the cache, the transcript id, the `model` setting, then 1M. A 200k family such as Haiku gets 200k and
an unknown model gets 1M. If the measured usage already exceeds whatever it settled on, the script
widens the window to 1M.

## Tests

```bash
python3 -m unittest discover -s plugins/runway/skills/runway/tests   # from the repo root
```

The suite runs on the standard library's `unittest`, with no dependencies to install. In-process
cases point the scripts at a temporary home and stub the credential read wherever they reach
`collect()`. Subprocess cases run under a temporary `HOME` that holds no credentials, so a test
run cannot reach the network.

## Limits worth knowing

- The context figure comes from the previous turn, because the transcript is written after a turn
  ends. Read it as a floor rather than a live gauge.
- A quota reset is a refill, not a deadline. 96% used with a reset in 5 minutes means you wait 5
  minutes.
- A brand-new session shows no context figure at startup, because it has no reply to measure
  yet. It never borrows the figure from an earlier session in the same project.
- Buckets marked `(<model> only - not this session)` belong to a model this session is not
  running. Runway decides this by matching the bucket's model name against the session's model id
  (from the hook payload, then the cached model, then the transcript id), because the API's
  `is_active` flag does not follow the running model. "Opus 5" matches `claude-opus-5` and
  `claude-opus-5[1m]` but not `claude-opus-5-5`. When such a bucket is tight, the hook prints a
  `runway IGNORE:` line instead of an action. A bucket with no model scope, such as the 5-hour
  limit, always counts.
- An expired token shows up as `HTTP 401`. Run `claude` to refresh it.
- Python 3.8+, standard library only. Keychain reads only work on macOS, and other platforms fall
  back to the credentials file.
