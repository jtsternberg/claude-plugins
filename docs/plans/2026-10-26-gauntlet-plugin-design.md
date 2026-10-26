# Design: `gauntlet` plugin v1 — the Gauntlet Loop as a native agent skill

**Status:** v2, awaiting review · **Date:** 2026-10-26 · **Source:** Tenex "Gauntlet Loop" playbook (Shumer)

## Recommendation (tl;dr)

One plugin, `plugins/gauntlet/`, two skills. `setup` helps an agent write a
project's **gauntlet harness** into a validated `gauntlet.json`. That covers the
goal, the reference bar, the criteria, how to capture a piece, and how to judge
it. `run` executes the loop from that spec. It is resumable and takes
`--status` / `--stop` / `--resume` flags.

The first value is that the loop becomes a skill agents reach for on their own
("gauntlet this", "make this beat X"), with the article's knowledge built in.
Nobody has to remember the article or paste its prompt. The second value is
that the plugin enforces the properties the article only asks for, which is
what makes the loop work reliably:

- loop decisions (which piece is next, blinding, un-blinding, stop rules) live
  in one stdlib-only Node script, `scripts/gauntlet.mjs`, so the model never
  decides "done" and never sees the blinding key;
- builders and critics are **hotline callees on herdr**, the same dispatch as
  agentic-dev. Each one is a fresh session in its own pane;
- the critic runs in a blind dir outside any repo and is limited to reading
  that dir.

The run works on a `gauntlet/<run-id>` branch and commits every round, so git
history is the record of progress.

v1 ships **plumbing plus a pluggable harness**, not a built-in judge for every
medium. The plumbing covers spec validation, dispatch, blinding, the ledger,
stop rules, the progress page, and status/stop/resume. Each project declares
its own harness: a `capture.command`, a `judge.prompt`, and a `medium` hint.
`image` and `text` ship as reference harnesses.

## Alternatives considered

| Approach | Verdict |
|---|---|
| Prompt-only skill (Step 8's paragraph as a SKILL.md) | Rejected. It is discoverable, but a prompt cannot keep the builder's context out of the critic or the key out of reach, and an unenforced blind test fails without anyone noticing |
| Workflow-tool script as the engine | Rejected. It is Claude-only, and it duplicates what hotline already gives both harnesses: fresh sessions, detached waits, resumable call dirs |
| `claude -p` / `codex exec` subprocesses the script spawns | Rejected as an engine. It would be a second dispatch stack to maintain next to hotline. Those modes stay available only as hotline's own `--headless` fallback |
| Script-owned loop + hotline/herdr callees (chosen) | One engine for both harnesses, the same shape as agentic-dev, and every guarantee is testable against a fake hotline root |

## Skill inventory

This is a single plugin, not a plugin group. `run` is useless without `setup`'s
spec, so the two are not the "related but independent" case that groups exist
for. `plugin.json` declares `"dependencies": ["hotline"]`, the same mechanism the
repo's bundle manifests use (see `plugins/pr-workflow/bundle/.claude-plugin/plugin.json`).
Hotline is a sibling in the same marketplace, so the dependency resolves on install.

```
plugins/gauntlet/
├── .claude-plugin/plugin.json      # dependencies: ["hotline"]
├── README.md
├── scripts/
│   ├── gauntlet.mjs        # validate | init | next | record | dispatch | await | blind | unblind | status | progress | stop | probe
│   ├── dispatch.sh         # one dial: env knobs + hotline dial.sh; prints call_dir
│   ├── lib-hotline.sh      # locate hotline + herdr capability check (pattern copied from agentic-dev's lib-hotline-herdr.sh)
│   └── lib/{png.mjs,text.mjs,ledger.mjs,rules.mjs,verdict.mjs,git.mjs}
├── references/
│   ├── judge-pairwise.md   # default judge.prompt for blind-pairwise
│   ├── judge-rubric.md     # default judge.prompt for rubric
│   ├── builder-order.md    # builder work-order template (stance + piece + gap)
│   ├── harness-image.md    # reference harness: Playwright screenshot capture
│   ├── harness-text.md     # reference harness: text section capture
│   └── spec-schema.json
├── skills/
│   ├── setup/SKILL.md + agents/openai.yaml
│   └── run/SKILL.md   + agents/openai.yaml
└── tests/  (see Test plan)
```

`lib-hotline.sh` resolves hotline in this order: `GAUNTLET_HOTLINE_ROOT`, then
`installed_plugins.json`, then `CLAUDE_PLUGIN_ROOT/../hotline`, then
`~/Code/claude-plugins/plugins/hotline`. It then greps `dial.sh` for `herdr` as
a capability check. No herdr means `run` refuses with a one-line reason;
gauntlet does not fall back to subprocess critics on its own. The
`GAUNTLET_HOTLINE_ROOT` override is also the test seam.

The scripts sit at the plugin root because both skills call them (repo rule:
shared code goes at the plugin root and resolves through the plugin-root token).
Every executable block in both SKILL.md files is:

Codex: this path resolves under Claude Code; substitute the installed plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/gauntlet.mjs" <subcommand> ...
```

repeated in full in every block (Codex shells keep no state).

### `gauntlet:setup`

```yaml
name: setup
description: >-
  Set up a Gauntlet Loop for a project: define the goal, the reference bar the
  work must beat, judging criteria beyond looks, how each piece is captured and
  judged (the project's harness), budget and stop rules, then write and
  validate a gauntlet.json spec. Use for "gauntlet this", "set up a gauntlet",
  "make this beat <reference>", "push this past good enough", "blind critic
  loop", "keep iterating until it beats X".
argument-hint: "[goal | path/to/gauntlet.json to revise]"
allowed-tools: "Read Write AskUserQuestion WebFetch Bash(node */scripts/gauntlet.mjs *) Bash(bash */scripts/dispatch.sh *) Bash(git *) Bash(npx playwright *)"
```

- Implicit invocation is allowed. At most, setup spends one probe dial per reference.
- Reads: an existing `gauntlet.json` if one is passed, the project itself (to
  write a harness that fits it), and any reference files or URLs the user names.
- Writes: `.gauntlet/<run-id>/gauntlet.json` and `.gauntlet/<run-id>/refs/*`.
  References are captured with the harness's own `capture.command`, so a ref
  and a candidate come out of the same pipeline. Setup does not touch
  `.gitignore` unless the user picks `git.commit_captures: false`; in that case
  it appends `.gauntlet/*/captures/` and `.gauntlet/*/refs/`.
- Flow: goal → bar (user-supplied refs, a named bar the run fetches, or
  image-model refs the user generates; setup does not call image models) →
  criteria → **harness**. If a reference harness fits (`references/harness-*.md`),
  the agent adapts it. Otherwise it writes `capture.command` and, if needed, a
  `judge.prompt`, then dry-runs the capture once on the current artifact.
  After that: the medium check and the **recognizability probe** (below) →
  ask whether the git remote is public and whether captures are committed →
  budget → stop rules → `gauntlet.mjs validate`. It ends by printing the spec
  path and the exact `run` command.
- Codex: the interview runs as plain chat turns (no AskUserQuestion). The
  `when_to_use` terms are already folded into `description` for Codex routing.

### `gauntlet:run`

```yaml
name: run
description: >-
  Run a Gauntlet Loop from a gauntlet.json spec: split the work into pieces,
  build each with a fresh hotline callee, capture the real output, judge it
  blind against the reference with an independent critic callee, commit each
  round, and loop until it wins, a stop rule fires, or you stop it. Also reports
  status of, stops, or resumes a run. Use for "run the gauntlet",
  "start/resume/stop the gauntlet", "gauntlet status".
argument-hint: "[run-dir] [--status | --stop | --resume]"
disable-model-invocation: true
allowed-tools: "Read Bash(node */scripts/gauntlet.mjs *) Bash(bash */scripts/dispatch.sh *) Bash(git *)"
```

- `disable-model-invocation: true` is mirrored by `policy.allow_implicit_invocation:
  false` in `skills/run/agents/openai.yaml`. A run can spend a subscription, so
  it starts only when asked.
- `$ARGUMENTS` is interpolated literally. Adjacent prose tells Codex to parse the
  same tokens from the user's message.
- The lead (the session running the skill) neither builds nor judges. It calls
  `next`, `dispatch`, `await`, and `record` (see `maestro:conduct`: boss/doer
  split). That is why `allowed-tools` has no Edit/Write: the code changes come
  from builder callees.
- Both harnesses use the same engine. Codex runs the same `gauntlet.mjs` calls;
  `judge.runner` decides which CLI the callee starts.

## `gauntlet.json`

The spec is immutable during a run, except for `budget` and `stop`: the human
may raise a cap mid-run, and `next` re-reads both on every call. The lead
decides the actual pieces in round 0 and records them in the ledger, not the
spec. That is the article's "let the agent split" rule.

```json
{
  "version": 1,
  "run_id": "landing-2026-10-26",
  "goal": "A landing page for the AI audit service that explains it clearly and gets the right visitors to book a call.",
  "artifact": {
    "workspace": "/Users/JT/Code/audit-site",
    "root": "site/",
    "serve": "npm run dev -- --port 5173",
    "url": "http://localhost:5173/"
  },
  "git": {
    "branch": "gauntlet/landing-2026-10-26",
    "base": "main",
    "worktree": "/Users/JT/Code/audit-site/.worktrees/gauntlet-landing-2026-10-26",
    "commit_captures": true
  },
  "medium": "image",
  "capture": {
    "command": "node .gauntlet/landing-2026-10-26/capture.mjs --piece {piece} --selector {selector} --out {out}",
    "ext": "png",
    "timeout_s": 120
  },
  "bar": [
    { "id": "ref-linear", "source": "https://linear.app", "file": "refs/ref-linear.png", "note": "hero clarity, density" },
    { "id": "ref-vercel", "source": "user-supplied", "file": "refs/ref-vercel.png" }
  ],
  "criteria": [
    { "id": "clarity", "ask": "Which makes it clearer who the service is for and what it does?" },
    { "id": "visual", "ask": "Which looks more polished and intentional?" },
    { "id": "cta", "ask": "Which makes the next step more obvious?" }
  ],
  "split_hints": ["hero", "explainer", "proof", "cta"],
  "judge": {
    "mode": "blind-pairwise",
    "prompt": null,
    "model": "claude-opus-5-5",
    "double": true,
    "harsh": true
  },
  "budget": {
    "max_rounds_per_piece": 12,
    "max_rounds_total": 40,
    "max_minutes": 180,
    "call_timeout_s": 3600
  },
  "stop": {
    "wins_to_close": 2,
    "plateau_rounds": 3,
    "smoothing_after_wave_changes": 2,
    "compromised_guess_rate": 0.8,
    "compromised_min_judgments": 5
  },
  "progress": { "publish": false }
}
```

- `artifact.workspace`: absolute path to the project the builders work in. It
  can be any repo on the machine, and a piece may override it with its own
  `workspace` (a split across a frontend repo and a docs repo, say). The
  gauntlet's own state lives in the run's worktree of the run-level workspace.
- `git.worktree`: one worktree per run on `git.branch`, created by `init` from
  `git.base`. Gauntlet never commits to the default branch and never force-pushes.
- `capture.command`: any command that writes exactly one capture file for a
  piece, using the tokens `{piece}`, `{round}`, `{out}`, and any key from the
  piece's `capture` object (here `{selector}`). It runs in the worktree. Exit
  non-zero or no file at `{out}` → a `capture_error` event (counts against
  rounds, not as a loss). The image reference harness ships a Playwright
  `capture.mjs` that setup copies into the run dir. A tests harness is just a
  `capture.command` that runs the suite and writes its output, judged by rubric
  or by a `judge.threshold` rule (a regex plus a minimum on the captured text),
  with no critic call.
- `medium`: a hint to the blinder, not a scope limit. `image` strips PNG
  metadata. `text` normalizes text. `opaque` does no stripping and forces
  `judge.mode: rubric`, for captures the blinder cannot make indistinguishable.
- `judge.prompt`: a template path. `null` means the bundled
  `references/judge-pairwise.md` or `judge-rubric.md` for the chosen mode.
- `judge.runner` (optional): `claude` | `codex`. When omitted it defaults to the
  current harness. Either harness can judge with either runner, if that CLI is
  installed.
- `bar[].file` is always a local file. URLs are captured at setup, so a
  reference can't change mid-run and the critic never touches the network.

### Ledger: `ledger.jsonl`, append-only, the only run state

Derived state like `status.json` is never stored. `gauntlet.mjs status` and
`next` fold the ledger on every call. Git records the *artifact*. The ledger
records the *run*. They join through the `commit` field on `built` events: the
ledger never re-derives anything from git, and git never holds a fact the
ledger needs. Resuming after a crash or compaction is just re-reading the ledger.

```json
{"ts":"2026-10-26T15:02:11Z","event":"split","pieces":[{"id":"hero","capture":{"selector":"#hero"},"ref":"ref-linear","workspace":null}]}
{"ts":"…","event":"dispatched","role":"builder","piece":"hero","round":3,"call_dir":"/…/hotline/calls/9f2c…","agent_name":"gauntlet-build-hero-r3","label":"build hero r3"}
{"ts":"…","event":"built","piece":"hero","round":3,"call_dir":"…","callee_session_id":"…","wait_rc":0,"commit":"4e1a9c0","gap_addressed":"headline never says who it's for"}
{"ts":"…","event":"captured","piece":"hero","round":3,"file":"captures/hero/r3.png","sha256":"…"}
{"ts":"…","event":"dispatched","role":"critic","piece":"hero","round":3,"pass":1,"token":"b7f2…","call_dir":"…","agent_name":"…","label":"judge hero r3"}
{"ts":"…","event":"judged","piece":"hero","round":3,"token":"b7f2…","callee_session_id":"…","wait_rc":0,"ours":"B","winner":"A","ref_won":true,"confidence":4,"guess_ours":"B","guess_correct":true,"criteria":{"clarity":"A","visual":"tie","cta":"A"},"biggest_gap":"Proof row is a logo wall with no claim attached","swap_agreed":true,"mode":"blind-pairwise"}
{"ts":"…","event":"closed","piece":"hero","round":5,"reason":"wins_to_close"}
{"ts":"…","event":"plateaued","piece":"proof","round":7,"reason":"3 losses, confidence not dropping"}
{"ts":"…","event":"smoothed","wave":2,"touched":["hero","cta"],"commit":"…"}
{"ts":"…","event":"reopened","piece":"cta","reason":"lost re-judge after smoothing"}
{"ts":"…","event":"stopped","reason":"human"}
```

`dispatched` and its completion event are separate on purpose. A `dispatched`
event with no completion event is a call in flight, and `await` re-waits on its
`call_dir` after a crash. This is agentic-dev's idempotent re-wait.

Per-piece derived state: `open | closed | plateaued | reopened`, round count,
win/loss streak, last gap, and guess accuracy.

**Mapping to agentic-dev**, for anyone who knows that pipeline:

| agentic-dev | gauntlet |
|---|---|
| one phase (build, review, …) | one dispatch: `build <piece> r<n>` or `judge <piece> r<n>` |
| Beads epic, one task per phase, blocking deps | `ledger.jsonl`; `next` folds it to name the next wave |
| phase metadata (call_dir, agent_name, callee_session_id, pane_id, wait_rc, transcript_path) | the same fields on `dispatched` / `built` / `judged` |
| `dial-phase.sh` | `scripts/dispatch.sh` |
| `templates/stance.md` embedded by `work-order.sh` | `references/builder-order.md` and the judge templates, filled by `gauntlet.mjs` with literal `{{TOKEN}}` swaps, untrusted text fenced |
| one worktree per run, callees commit | same |
| trailer `Agentic-Dev: <role> run=<run>` | trailer `Gauntlet: <piece> r<n> run=<run>` |
| one herdr workspace per run, one tab per phase | `HOTLINE_HERDR_PLACEMENT=workspace`, `HOTLINE_HERDR_WORKSPACE=gauntlet <run-id>` |

The ledger stays JSONL rather than Beads. A run writes dozens to hundreds of
events, each round is run state rather than an issue, and `next` needs ordered
append-only reads that a bd query cannot give cheaply. Beads keeps what it is
for: follow-up issues a run discovers.

## Run engine

The skill's loop is deliberately dumb: call `next`, do what it says, `record`
the result, repeat. `next` returns one of:

```json
{"action":"split"}
{"action":"build","pieces":[{"id":"hero","round":4,"gap":"…"}]}
{"action":"judge","pieces":["hero","cta"]}
{"action":"smooth","wave":2}
{"action":"await","call_dirs":["…"]}
{"action":"stop","reason":"all_closed|budget:max_rounds_total|budget:max_minutes|plateau_all|human|history_rewritten"}
```

1. **Init.** `gauntlet.mjs init` creates the worktree on `git.branch` and copies
   the spec and refs into the run dir in that worktree. The first commit is
   `gauntlet: init <run-id>`.
2. **Split** (round 0). The lead reads the spec and `split_hints`, then picks the
   smallest independently judgeable pieces, each with its capture arguments and
   the reference it is judged against. It runs `record split`. A piece with no
   matching reference region is judged against the whole reference (the
   borrowed-bar case).
3. **Build.** Within a wave, `next` hands out builds **one piece at a time**.
   `dispatch.sh` dials into the run worktree:
   `bash "$HOTLINE/skills/dial/scripts/dial.sh" --target <worktree> --transport herdr --detached --fresh --mode work_order --label "build <piece> r<n>" --prompt-file <order>`
   with `HOTLINE_CALLEE_ENV="GAUNTLET_ROLE=builder GAUNTLET_RUN=<id> GAUNTLET_PIECE=<piece>"`,
   `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1`, and the herdr placement env. The
   work order (`builder-order.md`) carries the goal, the piece, the criteria,
   the reference file path (builders *may* see the bar), and only the last
   verdict's `biggest_gap`. The builder commits its change with the
   `Gauntlet: <piece> r<n> run=<id>` trailer and ends on a `STATUS:` line.
   `await` runs `wait-for-response.sh <call_dir> --timeout <call_timeout_s>`
   and maps its exit codes. Exit 0 → `built`, with `commit` read from the
   trailer. Exit 4 (awaiting review) or 5 (blocked) → the event is recorded and
   the run pauses, telling the human which pane to look at. Exit 3 (preempted)
   or 1 (failed) → `build_error`, which counts against rounds.
4. **Capture.** `gauntlet.mjs` runs `capture.command` in the worktree after the
   build commit. The critic judges this file, never the builder's description
   of it.
5. **Judge.** Critics *are* parallel: they read only their blind dirs and never
   touch the tree. For each piece, `blind` → `dispatch` (critic) → `await` →
   `unblind` (contract below), and the run appends `judged`. The script then
   commits `.gauntlet/<run>/` with `Gauntlet: <piece> r<n> verdict=<won|lost|tie> run=<id>`.
   That verdict commit is made by the script, not by a model. It is the one
   exception to "callees commit, never the boss", and it touches only the run dir.
6. **Rules.** `next` applies the stop rules, closes, plateaus, or reopens
   pieces, and decides the next wave. Pieces close independently, and open
   pieces keep looping. Before every build, `next` checks that the last
   recorded build commit is still an ancestor of HEAD. If it is not, the run
   records `history_rewritten` and stops.
7. **Smooth.** When smoothing triggers, one fresh builder callee (`smooth w<n>`)
   sees the assembled whole and makes it cohere, then commits. Every closed
   piece it touched is re-captured and re-judged once, and a loss reopens it.
8. **Report.** On `stop`, `gauntlet.mjs status` prints per-piece standing,
   branch, and head commit. The skill shows that table and the progress page path.

**Worktree strategy: one worktree per run, builds sequential within a wave,
judges parallel.** Parallel builders in one tree collide on shared files
(stylesheet, layout, config) and race the capture: a screenshot taken while
another builder is mid-edit judges a hybrid. A worktree per piece would remove
the race, but it adds a merge step. Pieces of one artifact share files, so that
merge conflicts more often than not, and a merged result is something no critic
judged. Judging is where the wall clock goes (two passes with `double: true`),
and judging is safe to parallelize. So the sequential part costs roughly the
build time, not the loop time. Per-piece worktrees are a v2 option for
artifacts whose pieces live in disjoint files.

**Waiting.** `await` blocks on one or more `call_dir`s. Claude Code runs it as a
backgrounded Bash call (`run_in_background`) and is woken on exit, never as a
Monitor (30-min cap) and never as a sleep loop. Codex runs it in the foreground
with the same timeout. Either way, a crash mid-wait loses nothing: the
`dispatched` events name the call dirs to re-wait on.

**Quota:** if a `runway` wrap-up notice arrives mid-run, the lead finishes the
current `record` and hands off to `delayed-work:until` for the reset. Callees
already dialed keep running in their herdr panes, and `--resume` re-waits on
them. The skill names this in prose only; there is no hard dependency.

## Blinding contract

`gauntlet.mjs blind --piece <id> --ours <capture> --ref <ref-file> --seed <n>`

- Creates `~/.gauntlet/blind/<token>/`, a fixed root **outside every repo**
  (not a git dir, so no project or ancestor CLAUDE.md and no `.gauntlet/`).
  `<token>` is 128 random bits. Setup's probe dial lands in this root first,
  so any trust prompt shows up during setup and is answered once, not mid-run.
- Writes exactly `A.<ext>` and `B.<ext>`. The assignment is a seeded coin flip.
  The seed and mapping go to `~/.gauntlet/keys/<run-id>/<token>.json`, which is
  outside the blind dir and outside the worktree. That keeps keys out of git
  and away from builders. After `unblind`, the ledger carries the mapping
  (`ours`) and the key file is deleted.
- Strips identity per `medium`:
  - `image` (PNG): re-emits only `IHDR/PLTE/IDAT/IEND` (+ `tRNS`) and drops
    `tEXt/iTXt/zTXt/eXIf/tIME`. This is a pure Node chunk rewrite with no image
    deps. If dimensions differ in aspect ratio by more than 10%, the event gets
    `blind_weak:"aspect"`.
  - `text`: NFC-normalize, convert smart quotes to straight, collapse
    whitespace, drop front matter and heading markup, and drop any line
    matching the run's own identifiers (piece id, run id, file names).
  - `opaque`: no stripping, and the piece is forced to rubric mode.
  - For every medium, `utimes` sets a fixed epoch. File names, mtimes, and
    sizes are the only metadata the critic sees.
- **The critic is a hotline callee.** `dispatch.sh` runs dial.sh **with cwd set
  to the blind dir**. hotline puts the dialer's cwd in the `[CALLER: …]` tag, so
  dialing from the worktree would hand the critic the project path:
  `dial.sh --target <blind-dir> --transport herdr --detached --fresh --mode work_order --label "judge <piece> r<n>" --tools "Read(./**)" --prompt-file <blind-dir>/../<token>.prompt.md`
  with `HOTLINE_CLAUDE_MODEL=<judge.model>`, `HOTLINE_CALLEE_ENV="GAUNTLET_ROLE=critic GAUNTLET_RUN=<id>"`,
  and **no** `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS`. The critic's only
  pre-approved tool is reading its own dir. A read anywhere else hits a
  permission prompt, the pane goes `blocked`, `await` gets exit 5, and the run
  records `critic_strayed`. That event counts as a `judge_error` and is
  reported in `status`. Detection is the guarantee, because the
  `[SESSION: …]` tag still names the lead's session, and an unrestricted Read
  could open its transcript.
- `double: true` judges twice with the assignment swapped, as two independent
  `--fresh` dials. A win counts only if both passes agree (`swap_agreed`);
  disagreement is a tie. This cancels the first-position bias pairwise LLM
  judges are known for.
- **Verdict extraction.** The judge template requires the response to end
  with a fenced ```` ```json ```` block, then the `STATUS:` line. `await` takes
  the response text `wait-for-response.sh` prints on exit 0 and parses the
  **last** ```` ```json ```` fence (earlier fences may be the critic quoting
  the schema). It validates against
  `{winner: A|B|tie, criteria: {<id>: A|B|tie}, biggest_gap, confidence: 1-5, guess_ours: A|B|unsure}`.
  Invalid or missing JSON → one follow-up dial to the same call (no `--fresh`)
  that asks for the JSON block alone → still invalid → `judge_error` (counts
  against rounds, not as a loss).
- `unblind --token` reads the key, maps `winner` / `criteria` / `guess_ours` back
  to ours/ref, deletes the blind dir and the key file, and records the event.

### When blinding is impossible → rubric

Blinding fails in two measurable ways, and each one switches the piece to rubric mode:

1. **Recognizable reference** (setup time). The probe dials the critic with
   the reference alone: "Do you recognize the specific source of this? Name it
   or say no." If it names the source correctly (or names anything matching
   `bar[].source`), that reference gets `judge.mode: rubric`. One dial per ref.
2. **Medium or style giveaway** (run time). Every verdict carries `guess_ours`.
   Once a piece has at least `compromised_min_judgments` judgments with guess
   accuracy at or above `compromised_guess_rate`, `next` records
   `blind_compromised` and switches that piece to rubric. A real Call of Duty
   frame next to a Three.js render lands here.

In rubric mode the critic sees `REFERENCE` and `CANDIDATE`, labeled, and scores
the candidate 1–10 per criterion, where 7 is defined as "holds up next to the
reference". A rubric round is a **win** when every criterion scores 7 or more.
The ledger marks these `mode:"rubric"` and `status` reports them separately,
because a labeled judge is softer and JT should know which wins were blind.

## Stop rules (all evaluated by `next` on every call)

| Rule | Behavior |
|---|---|
| Win | `wins_to_close` consecutive wins (swap-agreed if `double`) → `closed` |
| Plateau | `plateau_rounds` consecutive losses **and** critic confidence not dropping across them → `plateaued`; the piece stops consuming builds. Confidence falling while still losing is progress, so the loop keeps going |
| Per-piece cap | `max_rounds_per_piece` → `plateaued` with `reason:"cap"` |
| Spend cap | `max_rounds_total` or `max_minutes` hit → `stop` after the in-flight wave records. An interactive callee reports no dollar cost, so the budget is rounds plus wall clock, stated plainly in `status`. `status` also prints the latest `runway` quota line when that skill is installed |
| Human stop | `run --stop` writes `.gauntlet/<run>/STOP`; `next` checks it first and returns `stop:human`. Callees already in flight finish and are recorded on `--resume`, which deletes `STOP` and continues from the ledger |
| History rewritten | the last build commit is no longer an ancestor of HEAD → `stop:history_rewritten` |
| Smoothing | after a wave in which at least `smoothing_after_wave_changes` pieces changed, and once before the final stop → `smooth` |
| All done | every piece `closed` or `plateaued` → final smooth (if anything changed since the last one) → `stop:all_closed` |

## Progress page

`gauntlet.mjs progress` rewrites `.gauntlet/<run>/progress.html` after every
`record`. The page is self-contained. For each piece it shows the latest
capture beside its reference, the streak, the last gap, and the round's commit.
It is committed with the run dir, so any commit on the branch renders that
round's state. It stays local by default, because captures are screenshots
and screenshots stay local unless JT says otherwise. With
`progress.publish: true`, the run skill publishes it as a private Artifact
after each wave, for phone check-ins.

## Git record

- Branch `gauntlet/<run-id>` in a dedicated worktree, cut from `git.base`. It is
  never the default branch, nothing is ever force-pushed, and gauntlet never
  pushes at all. Pushing or opening a PR is the human's call (or a
  conductor's) after the run.
- Builder callees commit their changes, one or more commits per round, each
  with the `Gauntlet: <piece> r<n> run=<id>` trailer.
- The script commits `.gauntlet/<run>/` (ledger, refs, captures, progress page)
  after each verdict, with the verdict in the trailer. `git log --grep 'Gauntlet:'`
  is therefore the full round-by-round history, and checking out any commit
  shows the artifact and its standing at that point.
- `git.commit_captures: false` keeps captures and refs out of the commits; the
  ledger and progress page are still committed. Setup asks about this when the
  remote is public, because captures are screenshots.

## Boundary

- **`maestro:conduct`**: the general orchestration stance (boss/doer, a fresh
  agent per phase, verify-before-relay). Gauntlet assumes that stance and adds
  what conduct doesn't have: an *external* bar, pairwise blind judging, and
  script-owned stop rules. A conductor may run a gauntlet as one phase.
- **`agentic-run`**: an issue → PR pipeline where the bar is "review findings
  addressed" plus tests. Gauntlet shares its dispatch shape (hotline on herdr,
  a worktree per run, callees commit) but stops at a branch and opens no PR.
  An agentic-run phase could invoke a gauntlet run to raise the quality of a
  build before review.
- **`skill-tools:review-skill`**: a single-pass review against best practices,
  with no reference and no loop. Gauntlet's rubric mode, with `references/` as
  the bar, could later cover Tenex's "skill library" example; v1 doesn't try.

## Test plan

All suites are discovered by glob. The default run makes no model calls, no
network calls, no herdr calls, and launches no real browser. Hotline is faked
the way agentic-dev's `dial-phase_test.sh` does it: the test builds a fake
hotline root whose `skills/dial/scripts/dial.sh` mentions `herdr` (to pass the
capability grep) and logs its argv, env, and cwd. Its `wait-for-response.sh`
replays a canned response and exit code per call dir. `GAUNTLET_HOTLINE_ROOT`
points at it.

| Suite | Path | Covers |
|---|---|---|
| node | `plugins/gauntlet/tests/spec.test.mjs` | `validate` against good/bad fixture specs; schema errors name the field; `opaque` forces rubric; `judge.runner` defaults to the current harness |
| node | `plugins/gauntlet/tests/blind.test.mjs` | seeded assignment is deterministic; key never written under the blind dir or the worktree; blind root outside any git dir; PNG metadata chunks gone, pixels byte-identical; text normalization; aspect `blind_weak`; unblind mapping incl. swap; key deleted after unblind |
| node | `plugins/gauntlet/tests/rules.test.mjs` | ledger fold → state; every stop rule from fixture ledgers (win streak, plateau with flat vs falling confidence, caps, STOP file, smoothing trigger, reopen, history rewritten); compromised-blind switch; rubric win threshold; in-flight `dispatched` without completion → `await` |
| node | `plugins/gauntlet/tests/dispatch.test.mjs` | against the fake hotline: builder argv (`--transport herdr --detached --fresh --mode work_order`, label, `--target` = worktree) and `HOTLINE_CALLEE_ENV`; critic argv has `--tools "Read(./**)"`, no skip-permissions env, **cwd = blind dir**, and a prompt holding only goal/criteria/A/B (no ledger text, no gap history, no project path); wait exit 0/3/4/5/1 → the right event; verdict = last ```json fence; malformed → one follow-up dial → `judge_error`; exit 5 on a critic → `critic_strayed`; one wave never has two builders in flight |
| node | `plugins/gauntlet/tests/git.test.mjs` | in a temp repo: `init` makes the worktree + branch, never touches the default branch; verdict commits carry the trailer; `commit_captures:false` leaves captures out; ancestor check trips on a reset |
| node | `plugins/gauntlet/tests/capture.test.mjs` | `capture.command` token substitution; non-zero exit / missing `{out}` → `capture_error`; the image reference harness with a stub `npx` writing a fixture PNG |
| bash | existing `plugins/codex/tests/skill-paths_test.sh` | path tokens in both SKILL.md files |
| node | existing `plugins/codex/tests/compatibility.test.mjs` + `validate-dual-harness-skill` | dual-harness contract, openai.yaml policy mirror |

There is no opt-in live suite, because adding one would change the documented
green skip count in CLAUDE.md. Instead a manual probe,
`node scripts/gauntlet.mjs probe --runner claude|codex`, does one real dial of
each kind on fixture images. One builder dial goes into a scratch repo. One
critic dial goes into a blind dir and checks that a stray Read really blocks.
Run the probe once per harness before release (the repo's "representative
probe in both harnesses" requirement).

Plus the standard new-plugin steps: a `marketplace.json` entry (description
copied verbatim), `node scripts/gen-codex-catalog.mjs`, and a README section.

## Estimate

| Scope | Work | Time |
|---|---|---|
| Claude-only | scripts (~850 lines incl. PNG/text libs, dispatch, git), two SKILL.md, three templates, two reference harnesses, schema, 6 node suites with the fake hotline root, Claude probe | 12–14 h |
| Dual-harness | + codex runner (hotline already dials either CLI), two openai.yaml, Codex probe and fixes from it | +2 h → 14–16 h |

Dual-harness costs less than in v1, because hotline replaces the separate Codex
build path. The single-harness work grows by the git record and the dispatch layer.

## Open decisions

- **critic-lockdown:** `tools-allowlist` (rec) | `hotline-deny-knob` — with the allowlist, a critic's stray Read blocks the pane and is *detected* (`critic_strayed`), but the read is not *prevented* if the callee runs with skip-permissions or the allowlist is widened. The deny knob adds a hotline change, `HOTLINE_CALLEE_PERMISSIONS_DENY` merged into the callee `--settings`, which would let gauntlet deny `~/.claude/projects/**`, the workspace, and `~/.gauntlet/keys/**` outright (~1 h in hotline plus its tests).
- **commit-captures default:** `true` (rec) | `false` — with `true`, the branch history shows every round's screenshot, and setup flips the default to `false` when the remote is public. With `false`, history holds only the ledger and progress page, and the screenshots live only on disk.
- **ledger-store:** `jsonl-only` (rec) | `jsonl+beads-run-task` — with beads, `init` also files one bd task per run (closed on stop) so the run shows in `bd ready`/`your-cue`. That gives visibility without moving round state into bd, but it adds a beads-workflow dependency and a bd call on Codex.
- **status/stop surface:** `flags-on-run` (rec) | `separate-skills` — separate skills mean `gauntlet:status`/`gauntlet:stop` SKILL.md files (implicit invocation is fine for status), the same script, +1 h, and two more openai.yaml.
- **wins_to_close default:** `2` (rec) | `1` — 1 halves judge dials per closed piece but lets a single lucky verdict close a piece, even with swap-double.
