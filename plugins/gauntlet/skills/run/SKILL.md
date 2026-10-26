---
name: run
description: "Run a Gauntlet Loop from a gauntlet.json spec: split the work into pieces, build each with a fresh hotline callee, capture the real output, judge it blind against the reference with an independent critic callee, commit each round, and loop until it wins, a stop rule fires, or you stop it. Also reports status of, stops, or resumes a run. Use for 'run the gauntlet', 'start/resume/stop the gauntlet', 'gauntlet status'."
argument-hint: "<path/to/gauntlet.json | run-dir> [--status | --stop | --resume]"
disable-model-invocation: true
allowed-tools: "Read Bash(node *)"
---

# Gauntlet: Run

You are the **lead**. You split the work once; after that you run one script and relay
what it says. You never build, judge, or edit files yourself: builders and critics are
fresh hotline callees on herdr, and the script owns blinding, the ledger, the stop
rules, and every decision about what happens next. You never push.

## Input

The request is `$ARGUMENTS`: a spec path (the `<workspace>/.gauntlet/<run-id>/gauntlet.json`
setup wrote) or a run dir, optionally followed by one flag.

Codex: if the token above is not substituted, read the path and flag from the user's message.

No spec yet? Stop and point at `/gauntlet:setup` (Codex: `$gauntlet:setup`).

## Flags

Codex: this path resolves under Claude Code; substitute the installed gauntlet plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" status --run <path>    # --status
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" stop --run <path>      # --stop
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" resume --run <path>    # --resume, then run the loop below
```

`--status` and `--stop` print and end the turn. `--stop` writes a STOP file; callees
already in flight keep running and are recorded on `--resume`.

## Start

`status` exits 3 when the run is not initialized yet. Then initialize it, which cuts
the `gauntlet/<run-id>` branch in its own worktree, copies the run dir there, files
one bd task in the project when it uses beads, and makes the first commit:

Codex: this path resolves under Claude Code; substitute the installed gauntlet plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" init <workspace>/.gauntlet/<run-id>/gauntlet.json
```

From here on, `--run` takes either path.

## The loop

Codex: this path resolves under Claude Code; substitute the installed gauntlet plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" loop --run <path>
```

It dials, waits, captures, judges, commits, and keeps going until it needs you. A
build or a judgment can take many minutes, so in Claude Code run it with
`run_in_background: true` and let its exit wake you; never poll it with sleeps. In
Codex, run it in the foreground with a long timeout. Either way, killing it loses
nothing: the ledger records every dial, and the next `loop` re-waits on calls in flight.
While it runs, `status` is safe to call for a progress line.

Its last output line is JSON. Act on `last.action`:

- **`split`** (first time only). Read the spec and `split_hints`, look at the project,
  and choose the smallest pieces a critic can judge on their own (a hero, a pricing
  table, one doc section). Give each its capture arguments and the reference it is
  judged against (`ref`, a `bar` id; defaults to the first). Record it, then run the
  loop again:

  Codex: this path resolves under Claude Code; substitute the installed gauntlet plugin directory.

  ```bash
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
  node "$PLUGIN_ROOT/scripts/gauntlet.mjs" split --run <path> --pieces '[{"id":"hero","note":"headline, subhead, primary CTA","capture":{"selector":"#hero"}}]'
  ```

- **`paused`**. A callee ended on AWAITING_REVIEW, is blocked waiting on a human, or
  is a builder that timed out, was preempted, or may have received its order despite
  a failed delivery, so it could still be working in the worktree. Tell the user which
  agent to look at (the status lines name it, with the `herdr agent attach` command
  and, for a builder, the `herdr pane close` command) and end the turn. They continue
  with `--resume`, which re-waits the call once; a builder that still has no answer is
  then recorded as a failed build. A callee parked on AWAITING_REVIEW gets one
  follow-up on that resume telling it the conductor is unattended and to finish; if
  it pauses again, the user answers it in its pane and runs `--resume`.
- **`stop`**. Show the status table, the branch, and the `progress.html` path, and
  end. `human` means a STOP file: say `--resume` continues. Every other reason is
  final for this run (`all_closed`, `plateau_all`, `budget:*`, `history_rewritten`).
- **`error`** or a non-zero exit. Report the message verbatim and stop. Do not work
  around it.

## Rules you keep

- The script decides when a piece is done. Never mark a piece closed, re-judge it, or
  skip a stop rule by hand.
- Do not read the critics' blind dirs or tell a builder anything the script did not
  put in its work order.
- The run branch is the record: `git log --grep 'Gauntlet:'` in the worktree shows
  every round. Pushing it or opening a PR is the user's call after the run.
- If a `runway` wrap-up notice arrives mid-run, let the current `loop` finish its step,
  then hand off to `delayed-work:until` for the reset. Callees keep running in their
  herdr panes, and `--resume` picks them up.
