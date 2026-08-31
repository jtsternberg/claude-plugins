# Beads Workflow Plugin

Skills for working through Beads epics and fixing multiple findings with granular issue and commit tracking. Claude Code installs them as a plugin; Codex can install either workflow as a standalone skill.

## Installation

```bash
# Claude Code
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install beads-workflow@jtsternberg
```

`beads-workflow` is not offered in the Codex-native plugin catalog. From this repository checkout, install one or both self-contained skills instead:

```bash
bash scripts/install-standalone-skill.sh beads-workflow:tackle-epic
bash scripts/install-standalone-skill.sh beads-workflow:fix-findings-beads-tasks
```

See the [standalone Codex skill guide](../../docs/codex/standalone-skills.md) for install scopes, copy mode, updates, and uninstalling.

## Dependencies

Install and configure [beads](https://github.com/steveyegge/beads):

```bash
npm install -g @beads/cli
```

## Skills

### `tackle-epic`

Work through a Beads epic, using a dedicated worktree by default, then create a pull request.

Invoke the skill with an epic ID or name. Add `--here` to work on the current branch instead of creating a worktree.

### `fix-findings-beads-tasks`

Fix a list of findings one at a time, with one Beads task and one commit per finding. Add `--push` to push each completed fix.

### `triage-beads`

Sweep every open bead and triage it against reality the way a careful engineer would by hand: close the ones already satisfied (with cited evidence — a version output, a passing test count, a commit SHA, a since-closed blocker), park the ones stuck on an external resource behind a ready-to-run playbook comment, and surface genuine human-only decisions into an end-of-run report instead of guessing. Add `--dry-run` to preview the plan without writing anything; `--status <list>` or `--label <label>` to scope the sweep. It only ever changes Beads state and adds comments, so it is safe to run repeatedly and unattended (e.g. from a scheduled agent).

Unlike the two workflows above, `triage-beads` is model-invocable on purpose — it fires on phrases like "triage beads" or "clean up stale issues" and can run on a schedule.

### `tripwire-scan`

Surface parked beads whose watched code a change-set touches — the edit-time warning `bd ready` can't give, because it fires only when someone asks for work, never when you edit the file a bead warns about. A parked bead declares where its knowledge bites in a `tripwire-paths:` line; this scans your diff against those anchors and reports each hit as `bead-id → matched file → the bead's one-line why`.

Anchors form a precision ladder — prefer the highest that fits: a `# tripwire: <bead-id>` **comment anchor** at the exact site (default — precise, self-announcing, and drift-proof because git relocates it), a **string anchor** (`path:"…"`), a **git-ref-pinned line-range** (`path@<ref>:Lstart-end` — a bare unpinned range is rejected, since line numbers drift), or a coarse **whole file** (`path`). Only open and blocked beads are scanned, so the `in_progress` bead you're editing a file to fix self-suppresses. Read-only and safe to run repeatedly; it degrades to an empty result where there is no beads db or git repo.

Like `triage-beads`, it is model-invocable — it fires on "check tripwires" / "scan for tripwires" and at review/PR time.

The plugin also ships a **`PostToolUse` hook** (Edit/Write/MultiEdit) that runs the same matcher on each edited file and injects a one-line reminder — the live edit-time trigger, for any agent, independent of whether anyone runs the scan. It fires at most once per file per session (keyed off the session id) and is Claude-primary.

The names above are the canonical skill names. Explicit invocation uses `/beads-workflow:tackle-epic`, `/beads-workflow:fix-findings-beads-tasks`, `/beads-workflow:triage-beads`, or `/beads-workflow:tripwire-scan` for the Claude plugin. Standalone Codex installs use `$tackle-epic`, `$fix-findings-beads-tasks`, or `$triage-beads` without a plugin namespace. The slash and dollar-sign forms are harness syntax, not part of the skill names.

`tripwire-scan` is Claude-plugin-only: it and its hook share a matcher at the plugin root (referenced via `${CLAUDE_PLUGIN_ROOT}`), so — unlike the other three — it cannot be installed as a standalone Codex skill (the standalone installer refuses plugin-root dependencies). Its review-time scan is a plain `bash plugins/beads-workflow/scripts/tripwire-match.sh scan` that any harness can run from a repo checkout.
