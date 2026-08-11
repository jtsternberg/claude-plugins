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

The names above are the canonical skill names. Explicit invocation uses `/beads-workflow:tackle-epic` or `/beads-workflow:fix-findings-beads-tasks` for the Claude plugin. Standalone Codex installs use `$tackle-epic` or `$fix-findings-beads-tasks` without a plugin namespace. The slash and dollar-sign forms are harness syntax, not part of the skill names.
