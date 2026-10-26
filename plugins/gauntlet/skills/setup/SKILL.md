---
name: setup
description: "Set up a Gauntlet Loop for a project: define the goal, the reference bar the work must beat, judging criteria beyond looks, how each piece is captured and judged (the harness), and the stop rules, then write and validate a gauntlet.json spec. Use for 'gauntlet this', 'set up a gauntlet', 'make this beat <reference>', 'push this past good enough', 'blind critic loop', 'keep iterating until it beats X'."
argument-hint: "[goal | path/to/gauntlet.json to revise]"
allowed-tools: "Read Write AskUserQuestion WebFetch Bash(node *) Bash(git *) Bash(gh repo view *) Bash(mkdir *) Bash(cp *)"
---

# Gauntlet: Setup

The Gauntlet Loop: build a piece, capture what it really produces, hand that and a
reference that is already excellent to a **fresh, harsh critic** that does not know
which is which, take the one gap it names, rebuild, and repeat until the piece wins.
Fresh context, a harsh prompt, two unlabeled files. That is the whole method.

This skill writes the spec the loop runs from. It builds nothing and judges nothing.
The run skill does that, and only when the user asks for it.

## Input

The request is `$ARGUMENTS`: either a goal in plain words or the path to an existing
`gauntlet.json` to revise.

Codex: if the token above is not substituted, read the goal or path from the user's message.

## Where things go

Everything lives in `<workspace>/.gauntlet/<run-id>/`: the spec as `gauntlet.json`,
references under `refs/`, and the harness's capture script if it has one. `<workspace>`
is the repo the builders will change (`git rev-parse --show-toplevel` from the current
directory, unless the user names another). Pick a short lowercase `run_id`, such as
`landing-2026-10-26`.

**Read `${CLAUDE_PLUGIN_ROOT}/references/spec.md`** for every field and its default.

Codex: substitute the installed gauntlet plugin directory for the path above.

## Interview

One question at a time, each with a recommended answer. (Codex: ask as plain chat
turns.) Skip any the request already answered.

1. **Goal.** What is the whole artifact for, and for whom? One or two sentences.
2. **The bar.** Which references must it beat? Files the user hands over, URLs to
   capture, or a named bar ("Linear's homepage") you capture. Never generate a
   reference yourself. A reference that is merely okay makes the loop worthless.
3. **Criteria.** Two to five questions the critic answers, each starting "Which…".
   At least one must be about the artifact doing its job (clarity, conversion,
   correctness), not only how it looks.
4. **Harness.** How a piece becomes one file the critic can read:
   - a web page or component → the image reference harness. **Read `${CLAUDE_PLUGIN_ROOT}/references/harness-image.md`**.
   - prose → the text reference harness. **Read `${CLAUDE_PLUGIN_ROOT}/references/harness-text.md`**.
   - anything else → write a `capture.command` that writes one file to `{out}`; if no
     blinding can hide which file is ours, set `medium: "opaque"` (forces rubric).

   Codex: substitute the installed gauntlet plugin directory for both paths above.

   Copy the harness script into the run dir when it uses one, then dry-run the capture
   once on the current artifact (step below). Capture each URL reference with the same
   harness into `refs/`, so ref and candidate come out of one pipeline.
5. **Judging.** `blind-pairwise` (default) or `rubric`. Recommend rubric only when a
   reference is so recognizable that the critic would know which file is which.
   `judge.double: true` judges twice with A/B swapped; it doubles critic calls.
6. **Git.** Check whether the remote is public:

   ```bash
   gh repo view --json visibility -q .visibility
   ```

   Captures are committed to the run branch by default. If the repo is public, ask
   whether they may be (`git.commit_captures`); screenshots can carry data.
7. **Budget and stop rules.** Offer the defaults from `spec.md` in one line and ask
   for changes. They can be raised mid-run by editing the run's `gauntlet.json`.

## Write and check

Write `<workspace>/.gauntlet/<run-id>/gauntlet.json`, then dry-run the capture and
validate. Use a piece id and capture arguments the split is likely to use.

Codex: this path resolves under Claude Code; substitute the installed gauntlet plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" try-capture <workspace>/.gauntlet/<run-id>/gauntlet.json --piece <id> --args '{"selector":"#hero"}'
```

Read the file it reports. A capture that does not show the piece is a harness bug;
fix it before going on.

Codex: this path resolves under Claude Code; substitute the installed gauntlet plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" validate <workspace>/.gauntlet/<run-id>/gauntlet.json
```

Fix every named field until it reports `"ok": true`.

## Hand off

Finish with the spec path and the command that starts the loop:
`/gauntlet:run <workspace>/.gauntlet/<run-id>/gauntlet.json` (Codex:
`$gauntlet:run <path>`). Say what a run spends: one builder session per piece per
round, one critic session per judgment (two with `double`), up to the budget.
