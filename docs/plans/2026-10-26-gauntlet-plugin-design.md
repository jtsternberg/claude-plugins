# Design: `gauntlet` plugin v1 — the Gauntlet Loop as a native agent skill

**Status:** v3, implemented on `feat/gauntlet-plugin` · **Date:** 2026-10-26 · **Source:** Tenex "Gauntlet Loop" playbook (Shumer)

## Recommendation (tl;dr)

One plugin, `plugins/gauntlet/`, two skills. `setup` helps an agent write a
project's **gauntlet harness** into a validated `gauntlet.json`: the goal, the
reference bar, the criteria, how to capture a piece, and how to judge it. `run`
executes the loop from that spec. It is resumable and takes `--status` / `--stop` /
`--resume` flags.

The method is what the article says: fresh context, a harsh critic prompt, and two
unlabeled files. The plugin's value is that the loop becomes a skill agents reach
for on their own ("gauntlet this", "make this beat X") with the method built in, so
nobody has to remember the article or paste its prompt. Enforcement beyond that is
a cost, not the product, so v1 adds only what is cheap or closes an obvious leak:

- loop decisions (which piece is next, blinding, un-blinding, stop rules) live in
  one stdlib-only Node script, `scripts/gauntlet.mjs`, so "done" is decided by the
  ledger fold rather than by a model's mood;
- builders and critics are **hotline callees on herdr**, the same dispatch as
  agentic-dev. Each one is a fresh session in its own pane;
- a critic sees a fresh temp dir holding two unlabeled files and is dialed from
  that dir, so hotline's `[CALLER:]` tag does not carry the project path.

The run works on a `gauntlet/<run-id>` branch and commits every round, so git
history is the record of progress.

v1 ships **plumbing plus a pluggable harness**, not a built-in judge for every
medium. Each project declares its own harness: a `capture.command`, a
`judge.prompt`, and a `medium` hint. `image` and `text` ship as reference harnesses.

## Alternatives considered

| Approach | Verdict |
|---|---|
| Prompt-only skill (Step 8's paragraph as a SKILL.md) | Rejected. Discoverable, but the loop's bookkeeping (who is next, which file is which, when to stop) drifts when a model carries it across dozens of rounds |
| Workflow-tool script as the engine | Rejected. Claude-only, and duplicates what hotline already gives both harnesses: fresh sessions, detached waits, resumable call dirs |
| `claude -p` / `codex exec` subprocesses the script spawns | Rejected as an engine: a second dispatch stack next to hotline |
| Script-owned loop + hotline/herdr callees (chosen) | One engine for both harnesses, the same shape as agentic-dev, testable against a fake hotline root |

## Skill inventory

A single plugin, not a plugin group: `run` is useless without `setup`'s spec.
`plugin.json` declares `"dependencies": ["hotline"]` (the field bundle manifests
use; `claude plugin validate` accepts it on a non-bundle plugin too).

```
plugins/gauntlet/
├── .claude-plugin/plugin.json      # dependencies: ["hotline"]
├── README.md
├── scripts/
│   ├── gauntlet.mjs        # validate | try-capture | init | split | next | loop | status | stop | resume | progress
│   └── lib/{spec,ledger,rules,blind,verdict,hotline,git,engine,progress}.mjs
├── references/
│   ├── stance-builder.md, stance-critic.md   # embedded at the top of every work order
│   ├── builder-order.md, smooth-order.md     # builder work orders
│   ├── judge-pairwise.md, judge-rubric.md    # default judge.prompt per mode
│   ├── harness-image.md + capture-image.mjs  # reference harness: Playwright element screenshot
│   ├── harness-text.md  + capture-text.mjs   # reference harness: markdown section copy
│   └── spec.md                               # field reference
├── skills/
│   ├── setup/SKILL.md + agents/openai.yaml
│   └── run/SKILL.md   + agents/openai.yaml   # disable-model-invocation + allow_implicit_invocation: false
└── tests/  (see Test plan)
```

Dispatch is Node, not bash: `lib/hotline.mjs` locates hotline (`GAUNTLET_HOTLINE_ROOT`
→ `installed_plugins.json` → `CLAUDE_PLUGIN_ROOT/../hotline` →
`~/Code/claude-plugins/plugins/hotline`, accepting the first whose `dial.sh` mentions
`herdr`), runs `dial.sh`, and runs `wait-for-response.sh`. One language keeps the
engine and its tests in one place. No herdr-capable hotline means `run` refuses with
a one-line reason. `GAUNTLET_HOTLINE_ROOT` is also the test seam.

Every executable block in both SKILL.md files is the repo's plugin-root form,
repeated per block with the Codex substitution sentence beside it.

### `gauntlet:setup`

Implicitly invocable; builds and judges nothing. Writes
`<workspace>/.gauntlet/<run-id>/gauntlet.json` plus `refs/` and any harness script.
Flow: goal → bar (user-supplied refs, or a named bar the agent captures; setup never
generates a reference) → criteria → harness (adapt a reference harness or write a
`capture.command`, then `try-capture` once on the current artifact) → judging mode →
git (asks about `commit_captures` when the remote is public) → budget/stop → `validate`.
Ends by printing the spec path and the `/gauntlet:run` command. Codex runs the
interview as plain chat turns.

### `gauntlet:run`

User-invoked only (a run spends sessions). The lead splits once, then runs
`gauntlet.mjs loop` and relays what it returns: `split`, `paused`, `stop`, or
`error`. It never builds, judges, edits, or pushes. Claude Code runs `loop` with
`run_in_background` and is woken on exit; Codex runs it in the foreground. `--run`
accepts the setup copy of the spec, mapping it to the run dir in the worktree.

## `gauntlet.json`

Fixed once `init` runs, except `budget` and `stop`, which `next` re-reads on every
step so a human can raise a cap mid-run. Pieces are decided by the lead at split
time and recorded in the ledger, not the spec (the article's "let the agent split").
Full field table: `references/spec.md`.

```json
{
  "version": 1,
  "run_id": "landing-2026-10-26",
  "goal": "A landing page for the AI audit service that explains it clearly and gets the right visitors to book a call.",
  "artifact": { "workspace": "/Users/JT/Code/audit-site" },
  "git": { "branch": null, "base": null, "worktree": null, "commit_captures": true },
  "medium": "image",
  "capture": {
    "command": "node .gauntlet/landing-2026-10-26/capture.mjs --url http://localhost:5173/ --selector {selector} --out {out}",
    "ext": "png",
    "timeout_s": 120
  },
  "bar": [{ "id": "ref-linear", "source": "https://linear.app", "file": "refs/ref-linear.png" }],
  "criteria": [
    { "id": "clarity", "ask": "Which makes it clearer who the service is for and what it does?" },
    { "id": "cta", "ask": "Which makes the next step more obvious?" }
  ],
  "split_hints": ["hero", "explainer", "proof", "cta"],
  "judge": { "mode": "blind-pairwise", "prompt": null, "model": null, "double": false },
  "builder": { "model": null },
  "budget": { "max_rounds_per_piece": 12, "max_rounds_total": 40, "max_minutes": 180, "call_timeout_s": 3600 },
  "stop": { "wins_to_close": 2, "plateau_rounds": 3, "smoothing_after_wave_changes": 2 }
}
```

- `git` defaults: branch `gauntlet/<run_id>`, base = the workspace's current branch,
  worktree `<workspace>-gauntlet-<run_id>`.
- `capture.command` runs in the worktree and writes one file to `{out}`. Tokens
  `{piece}`, `{round}`, `{out}`, `{run_dir}`, `{run_id}` and every key of the piece's
  `capture` object are substituted shell-quoted. Non-zero exit or an empty `{out}` →
  `capture_error` (counts against rounds, not as a loss).
- `medium`: `text` trims whitespace when blinding; `image` and `opaque` copy as is;
  `opaque` forces `judge.mode: rubric`.
- `judge.mode` is the user's choice; nothing switches it automatically.
- `bar[].file` is always a local file under the run dir, so a reference can't change
  mid-run and the critic never touches the network.

### Ledger: `ledger.jsonl`, append-only, the only run state

Nothing derived is stored; `next` and `status` fold the ledger on every call. Git
records the artifact, the ledger records the run, and they join through `commit` on
`built`/`smoothed`. Resuming after a crash or compaction is re-reading the ledger.

```json
{"ts":"…","event":"init","run_id":"landing-2026-10-26","worktree":"…","branch":"gauntlet/landing-2026-10-26","base":"main","bead":"site-g1"}
{"ts":"…","event":"split","pieces":[{"id":"hero","note":"…","ref":"ref-linear","capture":{"selector":"#hero"}}]}
{"ts":"…","event":"wave","wave":1,"builds":["hero","cta"],"rechecks":[]}
{"ts":"…","event":"dispatched","role":"builder","piece":"hero","round":1,"wave":1,"call_dir":"…","agent_name":"…","label":"build hero r1","trailer":"Gauntlet: hero r1 run=…"}
{"ts":"…","event":"built","piece":"hero","round":1,"wave":1,"call_dir":"…","wait_rc":0,"commit":"4e1a9c0…"}
{"ts":"…","event":"captured","piece":"hero","round":1,"wave":1,"file":"captures/hero/r1.png","sha256":"…"}
{"ts":"…","event":"dispatched","role":"critic","piece":"hero","round":1,"wave":1,"pass":1,"call_dir":"…","blind_base":"$TMPDIR/gauntlet-…","label":"judge hero r1"}
{"ts":"…","event":"verdict","piece":"hero","round":1,"pass":1,"ours":"B","winner":"ref","criteria":{"clarity":"ref","cta":"tie"},"biggest_gap":"…","confidence":4}
{"ts":"…","event":"judged","piece":"hero","round":1,"wave":1,"result":"lost","biggest_gap":"…","confidence":4,"mode":"blind-pairwise"}
{"ts":"…","event":"smoothed","wave":1,"commit":null}
{"ts":"…","event":"stopped","reason":"all_closed"}
```

Other events: `build_error`, `capture_error`, `verdict_malformed`, `judge_error`,
`smooth_error`, `paused`, `resumed`. A `dispatched` event with no terminal event for
its `call_dir` is a call in flight; `next` returns `await` and `loop` re-waits on it
(agentic-dev's idempotent re-wait). Per-piece state is folded: `open | closed |
plateaued | recheck`, rounds, win/loss streaks, last gap.

**Mapping to agentic-dev:**

| agentic-dev | gauntlet |
|---|---|
| one phase | one dispatch: `build <piece> r<n>`, `judge <piece> r<n>`, `smooth w<n>` |
| Beads epic, one task per phase | `ledger.jsonl`; one bd task per run for visibility |
| `dial-phase.sh` | `lib/hotline.mjs` + `lib/engine.mjs` |
| `templates/stance.md` embedded in each order | `references/stance-*.md` embedded in each order |
| one worktree per run, callees commit | same |
| trailer `Agentic-Dev: <role> run=<run>` | trailer `Gauntlet: <piece> r<n> run=<run>` |
| one herdr workspace per run | `HOTLINE_HERDR_PLACEMENT=workspace`, `HOTLINE_HERDR_WORKSPACE=gauntlet-<run-id>` |

Beads holds one task per run (filed by `init` in the target project when it has
`.beads/`, closed on a final stop) so a run shows up in `bd ready` and `your-cue`.
Round state stays in JSONL: dozens to hundreds of ordered events are run state, not
issues.

## Run engine

`loop` repeats: call `next`, do what it says, record the result. `next` returns one of
`split`, `wave`, `build`, `judge`, `smooth`, `await`, `paused`, `stop`, `error`.
`loop` hands control back to the lead on `split`, `paused`, `stop`, and `error`.

1. **Init.** Creates the worktree on `git.branch` from `git.base`, copies the run dir
   into it, writes a run-dir `.gitignore` when `commit_captures` is false, files the
   bd task, and commits `gauntlet: init <run-id>`.
2. **Split** (round 0). The lead picks the smallest independently judgeable pieces,
   each with capture arguments and the reference it is judged against, and records
   them with `split`.
3. **Wave.** A wave builds every open piece once, then judges every piece it built
   plus any closed piece awaiting a re-judge.
4. **Build.** One piece at a time:
   `dial.sh --target <worktree> --transport herdr --detached --fresh --mode work_order --label "build <piece> r<n>" --prompt-file <order>`
   from the worktree, with `HOTLINE_CALLEE_ENV="GAUNTLET_ROLE=builder GAUNTLET_RUN=<id> GAUNTLET_PIECE=<piece>"`,
   `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1`, `HOTLINE_CLAUDE_MODEL` when set, and the
   herdr placement env. The order carries the stance, goal, piece, criteria, the
   reference path (builders may see the bar), its last capture, and the last
   verdict's `biggest_gap` fenced as data. `wait-for-response.sh <call_dir>` exit codes
   map to events: 0 → `built` (commit found by its trailer; none → `build_error`),
   4 or 5 → `paused` (the run stops and names the agent to look at), 3 or 1 →
   `build_error`. The capture runs right after the build commit, before the next
   builder starts, so a capture never judges a hybrid.
5. **Judge.** Critics run in parallel. For each piece and pass: blind → dial →
   wait → unblind → `verdict`. When every pass is in, the script records `judged`
   and commits the run dir with `Gauntlet: <piece> r<n> verdict=<won|lost|tie|error> run=<id>`.
   That commit is the script's, and it touches only the run dir.
6. **Rules.** `next` applies the stop rules below. Before every build it checks that
   the last recorded build commit is still an ancestor of HEAD.
7. **Smooth.** One fresh builder callee (`smooth w<n>`) sees the whole and makes it
   cohere. If it commits, every closed piece is re-judged in the next wave without a
   build; a loss reopens it. No commit means nothing to re-judge.
8. **Report.** On `stop`, `status` prints per-piece standing, branch, head, and the
   progress page path.

**One worktree, builds sequential, judges parallel.** Parallel builders in one tree
collide on shared files and race the capture. A worktree per piece removes the race
but adds a merge that conflicts more often than not and yields something no critic
judged. Judging is safe to parallelize, so the sequential part costs build time only.

**Trust dialog.** A callee in a repo Claude Code has never trusted parks on the
startup trust dialog and hotline fails the dial at `deliver`/`boot`/`fire`. The
engine reads the callee's screen, sends `down enter`, waits for idle, and re-dials
the same target without `--fresh`, once (logic copied from agentic-dev's
`dial-phase.sh`). That needs the failed call dir to name its herdr agent. A live run
against a fresh `git init` on hotline 0.39.1 failed at `boot` ("blocked during
startup") with no agent left to read, so that failure is recorded with a hint to run
`claude` once in the workspace and trust it. Critic dirs are not git repos and are
never gated; a worktree of a trusted repo is not gated either, which is the normal case.

**Quota.** On a `runway` wrap-up notice the lead lets the current step finish and
hands off to `delayed-work:until`. Callees keep running in their panes; `--resume`
re-waits on them.

## Blinding

- `blind` makes a fresh `mkdtemp` dir under `$TMPDIR` holding `blind/A.<ext>` and
  `blind/B.<ext>` (a plain copy; `text` is whitespace-trimmed). The assignment is a
  coin flip seeded by run, piece, round, and wave, so a resumed run re-blinds the same
  way. `key.json` and the prompt sit beside `blind/`, not in it.
- **The critic is a hotline callee** dialed with cwd and `--target` set to the blind
  dir, `--fresh`, `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1`,
  `HOTLINE_CALLEE_ENV="GAUNTLET_ROLE=critic …"`, and `HOTLINE_CLAUDE_MODEL=<judge.model>`.
  Its prompt carries the stance, goal, criteria, and the two file names, and tells it
  to read only those. No ledger text, gap history, or project path. That is the whole
  critic lockdown: a fresh session, a dir with two files, and an instruction.
- **Verdict.** The template asks for one fenced ```` ```json ```` block, then the
  STATUS line. The engine parses the **last** fence (earlier ones may quote the
  schema) and validates `{winner: A|B|tie, criteria: {<id>: A|B|tie}, biggest_gap,
  confidence: 1-5}`. Malformed → one follow-up dial to the same critic (no
  `--fresh`) asking for the block alone → still malformed → `judge_error` (counts
  against rounds, not as a loss).
- `unblind` maps `winner` and `criteria` back to ours/ref and the temp dir is deleted.
- `judge.double: true` (default false) judges twice with the assignment swapped, as
  two `--fresh` dials. A win counts only when both passes agree; disagreement is a tie.
- **Rubric mode** (`judge.mode: rubric`, chosen by the user, forced by `opaque`): the
  critic sees `reference.<ext>` and `candidate.<ext>`, labeled, and scores 1–10 per
  criterion, 7 meaning "holds up next to the reference". A round wins when every
  criterion scores 7+. The ledger marks these `mode:"rubric"`.

## Stop rules (all evaluated by `next` on every call)

| Rule | Behavior |
|---|---|
| Win | `wins_to_close` consecutive wins → `closed`. A tie breaks the streak |
| Plateau | `plateau_rounds` consecutive losses → `plateaued` |
| Per-piece cap | `max_rounds_per_piece` → `plateaued` with `reason:"cap"` |
| Spend cap | `max_rounds_total` builds or `max_minutes` since `init` → no new builds; the wave's builds are still judged, then `stop`. Interactive callees report no dollar cost, so the budget is rounds plus wall clock |
| Human stop | `run --stop` writes `STOP`; `next` checks it first and returns `stop:human` without recording a final stop. `--resume` deletes it and continues |
| History rewritten | the last build commit is no longer an ancestor of HEAD → `stop:history_rewritten` |
| Smoothing | after a wave that built at least `smoothing_after_wave_changes` pieces, and once more when every piece is done if anything was built since the last smoothing |
| All done | every piece `closed` or `plateaued` → `stop:all_closed` (or `plateau_all` when none closed) |

A final stop (anything but `human`) is recorded, committed, and closes the bd task.

## Progress page

`progress.html` in the run dir is rewritten after every event: per piece, the latest
capture beside its reference, streaks, the last gap. It is committed with the run dir
and stays local.

## Git record

- Branch `gauntlet/<run-id>` in a dedicated worktree, cut from `git.base`. Gauntlet
  never pushes; pushing or a PR is the human's call after the run.
- Builders commit with `Gauntlet: <piece> r<n> run=<id>`; the smoother with
  `Gauntlet: smooth w<n> run=<id>`. The script commits only the run dir: at init,
  after every verdict, and at a final stop. `git log --grep 'Gauntlet:'` is the full
  history.
- `git.commit_captures: false` keeps `captures/` and `refs/` out of the commits via
  a run-dir `.gitignore`; the ledger and progress page are still committed.

## Boundary

- **`maestro:conduct`**: general orchestration (boss/doer, fresh agent per phase).
  Gauntlet adds an external bar, pairwise blind judging, and script-owned stop rules.
- **`agentic-run`**: issue → PR with "review findings addressed" as the bar. Gauntlet
  shares its dispatch shape but stops at a branch and opens no PR.
- **`skill-tools:review-skill`**: one pass, no reference, no loop.

## Test plan

Suites at `plugins/gauntlet/tests/*.test.mjs`, discovered by glob. The default run
makes no model, network, herdr, or browser calls. A fake hotline root
(`GAUNTLET_HOTLINE_ROOT`) whose `dial.sh` mentions herdr logs argv, env, cwd, and
prompt, plays the builder by committing with the trailer from the order, and whose
`wait-for-response.sh` writes a canned `response.json` and exits with the code the
test sets. `bd` and `herdr` are `PATH` stubs; git runs for real in temp repos.

| Suite | Covers |
|---|---|
| `spec.test.mjs` | defaults; errors name the field; `opaque` forces rubric; rubric never chosen automatically |
| `blind.test.mjs` | deterministic seeded assignment and pass-2 swap; blind dir holds only A/B, key outside it, not in a git repo; text trimming; unblind mapping; last-fence parsing; malformed reasons; tally (double agreement, rubric 7+) |
| `rules.test.mjs` | fold → state and every stop rule from fixture ledgers: sequential builds then judges, win streak, tie, plateau, cap, spend caps, STOP, recorded stop + resume, in-flight await, pause/resume, built-but-uncaptured, history rewritten, smoothing and re-judge reopen, no-commit smoothing, double passes |
| `dispatch.test.mjs` | builder and critic argv/env (herdr, detached, fresh, work_order, labels, skip-permissions on both, models, placement); critic cwd = target = blind dir, prompt without project/ledger/gap; builder gets the last gap; wait exits 4/5 → `paused`, 3/1 → `build_error`; critic exit 5 pauses then resumes; malformed → one non-fresh follow-up → `judge_error`; no trailer commit; never two builders in flight; double; rubric; trust dialog; dial failure; no herdr hotline; stop/resume |
| `git.test.mjs` | init makes worktree + branch and leaves the default branch alone; spec location rule; trailers on build and verdict commits; `commit_captures:false`; reset trips `history_rewritten`; bd task create/close and skip without `.beads/`; `--run` maps the setup copy |
| `capture.test.mjs` | token substitution and quoting; capture errors; `try-capture`; text harness section copy; image harness without Playwright; mid-run budget raise |
| existing codex suites | path tokens, dual-harness contract, openai.yaml policy mirror |

No opt-in live suite (it would change the documented skip count). Before release, do
one representative live run per harness: a two-piece text gauntlet in a scratch repo,
led once from Claude Code and once from Codex.

## Estimate

| Scope | Work | Time |
|---|---|---|
| Both harnesses | engine (~1,100 lines across `gauntlet.mjs` + libs), two SKILL.md + openai.yaml, templates, two reference harnesses, 6 node suites with the fake hotline root | 8–10 h |
| Live probes | one real run per harness and fixes from it | +1–2 h |

## Decided

- **Critic lockdown:** none beyond a fresh callee dialed from a temp dir holding only
  A and B. No hotline change, no tool allowlist.
- **Commit captures:** `true` by default; setup asks when the remote is public.
- **Status/stop surface:** flags on `run` (`--status`, `--stop`, `--resume`).
- **`wins_to_close`:** 2.
- **Ledger store:** JSONL for round state, plus one Beads task per run in the target
  project.
