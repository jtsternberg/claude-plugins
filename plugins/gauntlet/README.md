# gauntlet

The Gauntlet Loop as a native skill. Build a piece, capture what it really
produces, put it next to a reference that is already excellent, and have a fresh,
harsh critic pick the better one without knowing which file is which. The single
gap the critic names goes to the next builder. Repeat until the piece wins.

The method is three things: fresh context for every builder and critic, a harsh
critic prompt, and two unlabeled files. The plugin bakes that in so nobody has to
paste a prompt or remember the rules.

## Skills

| Skill | Claude Code | Codex | What it does |
|---|---|---|---|
| `setup` | `/gauntlet:setup [goal]` | `$gauntlet:setup` | Interviews for the goal, the reference bar, the criteria and the capture harness; writes and validates `<workspace>/.gauntlet/<run-id>/gauntlet.json` |
| `run` | `/gauntlet:run <spec> [--status\|--stop\|--resume]` | `$gauntlet:run` | Drives the loop. User-invoked only, because a run spends sessions |

## How a run works

1. `init` cuts `gauntlet/<run-id>` from the base branch in its own worktree, copies
   the run dir there, and files one bd task in the project if it uses beads.
2. The lead splits the work into the smallest pieces a critic can judge alone.
3. Each wave builds the open pieces **one at a time** (each a fresh hotline callee
   in the worktree, committing with a `Gauntlet: <piece> r<n> run=<id>` trailer),
   capturing each right after its commit.
4. Critics judge in parallel. Each gets a fresh `$TMPDIR` dir holding only `A.<ext>`
   and `B.<ext>` (assignment by seeded coin flip, key kept outside that dir), is
   dialed from that dir, and returns a JSON verdict. The script maps it back and
   commits the run dir with the verdict in the trailer.
5. Stop rules fold the append-only `ledger.jsonl`: `wins_to_close` wins close a
   piece, `plateau_rounds` losses plateau it, plus per-piece and total round caps, a
   wall-clock cap, and a STOP file. After a wave that changed enough pieces, and once
   before the end, a smoothing pass makes the pieces cohere; closed pieces are
   re-judged and a loss reopens them.

`progress.html` in the run dir is rewritten after every event. Gauntlet never pushes.

## Harnesses

A harness is how a piece becomes one file: `capture.command` plus a `medium` hint
(`image`, `text`, or `opaque`, which forces rubric judging). Two reference harnesses
ship in `references/`: a Playwright element screenshot (`harness-image.md`) and a
markdown-section copy (`harness-text.md`). Field reference: `references/spec.md`.

`judge.mode` is the user's choice: `blind-pairwise` (default) or `rubric` (labeled,
scored 1–10, a win is 7+ on every criterion) for references too recognizable to
blind. `judge.double: true` judges twice with A/B swapped.

## Requirements

- `hotline` with its herdr transport (declared as a plugin dependency), and `herdr`.
  The engine finds hotline via `GAUNTLET_HOTLINE_ROOT`, the installed plugin, a
  sibling plugin dir, or `~/Code/claude-plugins/plugins/hotline`, and refuses to run
  without herdr support.
- `git` and Node 20+. `bd` is optional.
- Every builder and critic runs with `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1`, because
  an unattended pane must not stall on a permission prompt.

Design record: [`docs/plans/2026-10-26-gauntlet-plugin-design.md`](../../docs/plans/2026-10-26-gauntlet-plugin-design.md).
