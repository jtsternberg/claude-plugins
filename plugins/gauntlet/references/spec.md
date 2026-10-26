# `gauntlet.json` fields

Lives at `<workspace>/.gauntlet/<run-id>/gauntlet.json`, beside its `refs/` and any
harness script. `gauntlet.mjs validate` checks it and names every bad field.

| Field | Default | Meaning |
|---|---|---|
| `version` | required | `1` |
| `run_id` | required | lowercase id; names the branch, worktree, and herdr workspace |
| `goal` | required | what the whole artifact is for, in one or two sentences |
| `artifact.workspace` | required | absolute path to the repo the builders work in |
| `medium` | required | `image` \| `text` \| `opaque`. `opaque` forces `judge.mode: rubric` |
| `capture.command` | required | shell command, run in the run's worktree, that writes one file to `{out}`. Tokens: `{piece}`, `{round}`, `{out}`, `{run_dir}`, `{run_id}`, plus every key of the piece's `capture` object. Values arrive shell-quoted |
| `capture.ext` | required | extension of the captured file (`png`, `md`) |
| `capture.timeout_s` | 120 | a slower capture is a `capture_error` |
| `bar[]` | required | references: `{id, file, source?, note?}`. `file` is relative to the run dir |
| `criteria[]` | required | `{id, ask}`: the questions the critic answers |
| `split_hints[]` | — | suggestions for the lead's split; the lead decides |
| `judge.mode` | `blind-pairwise` | or `rubric` (labeled, scored 1–10, a win is 7+ everywhere) |
| `judge.prompt` | bundled | template path (relative to the run dir) instead of the bundled one |
| `judge.model` / `builder.model` | hotline default | `HOTLINE_CLAUDE_MODEL` for that role |
| `judge.double` | `false` | judge twice with A/B swapped; a win needs both passes |
| `budget.max_rounds_per_piece` | 12 | then the piece plateaus (`cap`) |
| `budget.max_rounds_total` | 40 | builds across all pieces |
| `budget.max_minutes` | 180 | wall clock since `init` |
| `budget.call_timeout_s` | 3600 | per callee wait |
| `stop.wins_to_close` | 2 | consecutive wins that close a piece |
| `stop.plateau_rounds` | 3 | consecutive losses that plateau a piece |
| `stop.smoothing_after_wave_changes` | 2 | pieces built in a wave that trigger a smoothing pass |
| `git.branch` | `gauntlet/<run_id>` | run branch |
| `git.base` | workspace's current branch | branch the run is cut from |
| `git.worktree` | `<workspace>-gauntlet-<run_id>` | absolute path of the run's worktree |
| `git.commit_captures` | `true` | `false` keeps `captures/` and `refs/` out of git |

`budget` and `stop` are re-read on every step, so a cap can be raised mid-run. The
rest is fixed once `init` runs.
