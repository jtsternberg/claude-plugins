# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of Claude Code plugins (skills, commands, hooks) for sharing and reuse. Each plugin lives in its own directory under `plugins/`.

## Repository Structure

```
.claude-plugin/
├── plugin.json          # Plugin metadata
└── marketplace.json     # Marketplace registry of available plugins
plugins/
└── <plugin-name>/               # Each plugin in its own directory
    ├── .claude-plugin/
    │   └── plugin.json          # Plugin metadata (keep at the plugin root)
    ├── README.md                # Plugin-level docs
    ├── skills/                  # Skills live here (optional)
    │   └── <skill-name>/        # One directory per skill
    │       ├── SKILL.md         # The skill definition — belongs at this path
    │       └── scripts/         # Scripts the skill runs, bundled with it
    ├── commands/                # Slash command markdown files (optional)
    └── hooks/                   # Hook scripts (optional)
```

A directory under `plugins/` without its own `.claude-plugin/plugin.json` is a
**plugin group**: each of its immediate subdirectories is a plugin of the normal
shape above (see `plugins/pr-workflow/`). A group typically also holds a
`bundle/` plugin — a manifest with only `name` + `dependencies` — so one install
brings in every child. Tooling resolves a plugin root as the nearest directory
containing a plugin manifest; never assume `plugins/<name>` is a plugin root.

Each skill's `SKILL.md` belongs at `plugins/<plugin-name>/skills/<skill-name>/SKILL.md`. That path is what makes the skill discoverable in autocomplete. Claude Code invokes an installed plugin skill as `/<plugin-name>:<frontmatter-name>`; Codex invokes it as `$<plugin-name>:<frontmatter-name>`. Use the bare frontmatter name only when referring to the skill in prose. Keep `.claude-plugin/plugin.json` at the plugin root; everything a skill needs (its `SKILL.md` and any `scripts/`) sits together under its own `skills/<skill-name>/` directory.

## Dual-Harness Skill Contract

Every new or edited skill must preserve behavior under both Claude Code and Codex unless it is explicitly marked harness-specific. Skills are the authoring primitive and plugins are the distribution primitive: add reusable workflows as `skills/<name>/SKILL.md`, not `commands/*.md`. Before committing a skill change, run `validate-dual-harness-skill` against it and run the focused compatibility tests plus `bash tests/run-all.sh`; behavior involving path resolution, invocation, hooks, or permissions needs a representative probe in both harnesses.

The review must account for the actual contracts, not assume one harness mirrors the other: keep Codex routing terms in `description` because it ignores Claude's `when_to_use`; preserve Claude's literal `$ARGUMENTS` wherever positional interpolation matters and give Codex adjacent fallback prose; mirror `disable-model-invocation: true` with `policy.allow_implicit_invocation: false` in `agents/openai.yaml`; and treat Claude's `argument-hint`, `when_to_use`, `effort`, dynamic `!` context, and `allowed-tools` permission grants as Claude-only behavior unless current Codex evidence says otherwise. Keep `allowed-tools` synchronized with the commands Claude will actually execute.

Claude path tokens in executable skill text must remain bare `${CLAUDE_SKILL_DIR}` or `${CLAUDE_PLUGIN_ROOT}` tokens—never shell-default wrappers—so Claude Code can resolve them mechanically. Put Codex's instruction in adjacent prose without repeating the token there, and repeat the local assignment in every independently executed block because Codex shells do not retain state. Hook variables are a separate runtime contract; do not infer hook behavior from skill-shell behavior.

When a skill runs bundled scripts, reference them through the runtime-resolved skill path so they work from any working directory:

Codex: this path resolves under Claude Code; substitute the directory containing this `SKILL.md`.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/<script-name>" [args]
```

Use that form in every executable block in `SKILL.md`. Under Claude Code the bare token is mechanically resolved; under Codex the model substitutes the installed skill directory described in the adjacent prose. Keep any `allowed-tools` matcher aligned with the resulting Claude command. See `plugins/research-tools/skills/fetch-docs/SKILL.md` for a working example.

## Compounding Gotchas — consult before you build, add when you learn

[`docs/compounding.md`](docs/compounding.md) is this repo's ledger of
expensively-learned rules. Three mechanical triggers keep it live: the beads
`compounding-ledger` memory (injected each session by `bd prime`'s hooks) points
here, the repo-private `compounding-preflight` skill scans any change-set against
the rule headlines (run it when reviewing or creating a PR), and the
`publish-release` runbook runs that scan at ship time. The doc carries each
rule's provenance and a Known False Positives section listing what not to flag.
When a review round, correction, or cleanup teaches a durable, repeatable rule,
add an entry through the doc's write gate (provenance required) — and prune
entries a change makes obsolete. The ledger must not only grow. An entry that
duplicates a rule this file already states gets a pointer here instead of a
restatement — two sources for one rule is itself entry-one's failure mode.

## Adding a New Plugin

1. Create a new directory under `plugins/<plugin-name>/`
2. Put `plugin.json` at `plugins/<plugin-name>/.claude-plugin/plugin.json`
3. For each skill, create `plugins/<plugin-name>/skills/<skill-name>/SKILL.md`, and bundle any scripts it runs in that same `skills/<skill-name>/scripts/` directory
4. Add hooks (`hooks/`) and slash commands (`commands/`) at the plugin root as needed
5. Register the plugin in `.claude-plugin/marketplace.json` by adding an entry to the `plugins` array
6. Update `README.md` with documentation for the new plugin

For a set of related but independent skills, prefer a plugin group of single-skill plugins plus a bundle (see `plugins/pr-workflow/`) over one multi-skill plugin.

To confirm a new skill sits where discovery expects it, check that it matches the others:

```bash
find plugins -name SKILL.md    # every result should be plugins/<plugin>/skills/<skill>/SKILL.md
                               # or plugins/<group>/<plugin>/skills/<skill>/SKILL.md
```

## Sharing Code or Docs Between Sibling Skills

When two or more skills in one plugin need the same script or the same reference doc, keep
**one copy at the plugin root** — `plugins/<plugin>/scripts/` and
`plugins/<plugin>/references/` — and resolve it from the plugin root.

Codex: this path resolves under Claude Code; substitute the installed plugin directory.

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
node "$PLUGIN_ROOT/scripts/thing.mjs" <args>
```

And to point the model at a bundled doc, give it a resolvable path:

Codex: substitute the installed plugin directory for the path below.

```markdown
**Read `${CLAUDE_PLUGIN_ROOT}/references/some-guide.md`** before continuing.
```

Claude Code mechanically resolves the bare plugin-root token to the installed plugin directory.
Codex does not expose that environment variable to skill shells, so the adjacent instruction
must tell it which directory to substitute. `plugins/session-tools/` is the reference example —
three skills share one transcript reader that had already drifted twice when duplicated.

Two things to avoid:

- **`${CLAUDE_SKILL_DIR}/../../`** — the skill token names the skill's own subdirectory;
  traversal out of it is unsupported. Use the plugin-root form above for shared resources.
- **Bare relative paths in SKILL.md prose** (`see references/foo.md`). Nothing resolves
  those for the model — there is no implicit base directory. Use a mechanically resolvable
  Claude path plus adjacent Codex substitution prose.

Duplicating a file across sibling skills is the thing this avoids: this repo has lost time
to exactly that, twice, in the transcript parser.

## Stance Skills Travel in a Set — Keep Them in Lockstep

Three skills teach the same operating stance and cannot be edited one at a time:

| File | Role |
|---|---|
| `plugins/fable/skills/fable-mode/SKILL.md` | canonical stance, for Claude models |
| `plugins/codex/skills/fable-mode/SKILL.md` | Codex A/B arm, Fable frame |
| `plugins/codex/skills/sol-mode/SKILL.md` | Codex A/B arm, Sol frame |

They deliberately **share no text.** The `codex/` pair paraphrases the stance because those
two exist to A/B a competitive frontier-model frame on Terra-class models, and they must
never claim to *be* Fable or Sol. So `grep` for a phrase you changed will not find them —
that is by design, and it is exactly how they drift.

Two rules when the stance changes:

1. **Propagate the substance to all three.** Match the idea, not the wording. A practice
   bullet or closing check added to the canonical file that never reaches the `codex/` pair
   leaves them teaching a strictly weaker stance.
2. **Keep the two `codex/` arms symmetric with each other.** Improving one arm and not the
   other makes the A/B measure your edit instead of the frame it was built to test. If you
   cannot do both, do neither and say so.

Also sweep what *asserts* the stance rather than stating it: `plugins/fable/README.md`,
`plugins/fable/skills/fable-mode/references/sonnet-guardrails.md` (which re-fences the same
practices for Sonnet), and the AM Skills overlay README if the plugin is mapped in
`.amskills.json`. None are derived from `SKILL.md`, all of them go stale when it changes.

## Plugin Types

### Hook-based plugins
Hook scripts in `hooks/` that intercept Claude Code events (permissions, notifications, etc.) and return JSON decisions.

### Skill-based plugins
Each skill is a `SKILL.md` at `skills/<skill-name>/SKILL.md`, with its scripts bundled in `skills/<skill-name>/scripts/` and referenced via `${CLAUDE_SKILL_DIR}/scripts/…`. This layout surfaces the skill in autocomplete. Invoke it as `/<plugin-name>:<frontmatter-name>` in Claude Code or `$<plugin-name>:<frontmatter-name>` in Codex.

### Command-based plugins
Markdown files in `commands/` that define slash commands Claude can invoke.

## Versioning

When a plugin change (skills, commands, hooks, metadata) is ready to ship, bump the version in its `.claude-plugin/plugin.json`. Use semver: patch for fixes, minor for new features or non-breaking changes, major for breaking changes.

Bump **once, at the end of the work session**, for the whole change-set — not on every iteration within a session. Iterate and commit freely while you work; do the single version bump when the change is done and about to be released. One release, one bump.

Manually invoke the `publish-release` skill when a release should be pushed. It is the manual entry point for shipping a plugin change to installers — version bump, validation, merge, and marketplace refresh across both harnesses — and points to the detailed runbook at [`docs/release.md`](docs/release.md).

## Keeping Third-Party Docs In Sync

Several skills wrap an external tool (e.g. `work-with-media:macwhisper-cli` wraps
the MacWhisper `mw` CLI). We vendor a cached copy of each such tool's upstream doc
under [`docs/third-party/cached/`](docs/third-party/cached/) so we can tell when the
tool changes and keep our wrapper docs from drifting. Each cached file is
self-describing: its frontmatter names the upstream `source`, its `last_updated`
date, and the local skills/docs it informs (`related`).

When the user says **"check for updated third party docs"** (to improve our docs),
invoke the repo-private `check-third-party-docs` skill
([`.claude/skills/check-third-party-docs/SKILL.md`](.claude/skills/check-third-party-docs/SKILL.md)).
It re-fetches each cached doc via `research-tools:fetch-docs`, overwrites the cached
copy so `git diff` shows exactly what changed upstream, then proposes edits to the
`related` skills/docs. It surfaces suggestions for review — it does not auto-apply.

## Development Commands

Repository-wide analysis scripts are documented in
[`scripts/README.md`](scripts/README.md). They are maintainer checks and report
generators, not plugin runtime dependencies; run them from the repository root
when auditing the current tree.

```bash
# Install plugin locally for testing
claude plugins add /path/to/claude-plugins/plugins/<plugin-name>

# Test hook scripts directly (pipe JSON input)
echo '{"tool_name":"Bash","cwd":"/path","tool_input":{"command":"ls"}}' | bash plugins/<plugin-name>/hooks/<hook-script>.sh
```

## Testing

One command runs every suite in the repo, across all three languages:

```bash
bash tests/run-all.sh
```

It exits 0 only when every suite that *could* run passed. A suite that cannot run —
its runtime is absent, or it is opt-in and not enabled — is reported as **SKIP**,
never silently passed, so read the summary, not just the exit code.

**A skip is only honest if something can actually satisfy it.** The gws suites were
gated on `import pytest` while CI installed no python packages, so 54 tests were
permanently skipped and the run still exited 0 — indistinguishable from a real pass
unless you read the summary line. Before gating a suite on a runtime, confirm CI
installs that runtime.

CI (`.github/workflows/tests.yml`) runs exactly that script on pushes to `main`, on
pull requests, and on manual dispatch. It runs on **ubuntu-latest** on purpose: these
suites also have to keep working on the Linux box.

A green run reports **`skipped 1`** — `codex: live-plugin`. That suite installs the
plugin into a scratch `CODEX_HOME` and calls the real API, so it is opt-in: it runs
only with `CODEX_LIVE=1` plus the `codex` CLI and `OPENAI_API_KEY`, and skips
everywhere else, CI included. Every other suite runs on every machine — the cmux
suites stub `cmux` via `PATH` rather than skipping on Linux. Treat a skip count
above 1 as something to read rather than expected noise.

### Put a new suite where the runner will find it

Suites are **discovered by glob, not listed** — a hardcoded list silently omits new
tests, which is exactly how the handoff plugin shipped 14 passing tests that CI never
ran. Match one of these paths and it is covered automatically:

| Language | Path | Runner |
|---|---|---|
| bash | `plugins/<plugin>/tests/<name>_test.sh` | `bash` |
| node | `plugins/<plugin>/skills/<skill>/tests/<name>.test.mjs` | `node --test` |
| node | `plugins/<plugin>/tests/<name>.test.mjs` | `node --test` |
| python | `plugins/<plugin>/skills/<skill>/tests/test_*.py` | `unittest discover` |
| python | `plugins/<plugin>/tests/test_*.py` | `unittest discover` |

Plugins inside a plugin group match the same five paths one level deeper —
`plugins/<group>/<plugin>/tests/<name>_test.sh` and so on. The runner globs both
depths; a suite label for a nested plugin reads `group/child`.

Python suites must be **stdlib `unittest`** — `unittest discover` collects only
`unittest.TestCase` subclasses, so a pytest-style module of bare `def test_x()`
functions would be silently ignored. The runner greps for `import unittest` in every
`test_*.py` and fails the suite if it's missing, rather than quietly not running it.
There is no pytest path; don't add one without also installing pytest in CI.

Bash suites should print `N passed, M failed` and exit non-zero on failure. If a suite
needs a tool that may be absent, self-skip with exit 0 and say so on stdout.

Anything that reaches a real database, a real API, or `cmux` must be stubbed — the
handoff suite stubs `bd` via `PATH`. Tests must never touch a real beads database.

### The parser drift guard

`tests/parser-drift.test.mjs` asserts that `session-tools`' `lib/transcript.mjs` (the
source of truth for reading Claude Code transcripts) and `hotline`'s
`switchboard/scripts/server.js` still agree on what counts as harness noise and what a
compaction boundary looks like. They silently diverged twice before this existed. If you
change transcript-parsing behavior in either, expect this to fail — and fix both.

Read its header before adding a third implementation to the comparison: the jq and
Python readers are excluded deliberately, and the reasons are documented there.

---

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## General Rules

- **NEVER commit HANDOFF*.md files** - They are session artifacts only, not repo files

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd dolt push          # Push beads to Dolt remote
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - `bash tests/run-all.sh` (see [Testing](#testing)); check the summary for SKIPs, not just the exit code
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->
