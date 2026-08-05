# Beads Workflow Plugin

Skills for working through Beads epics and fixing multiple findings with granular issue and commit tracking. Both workflows work in Claude Code and Codex.

## Installation

```bash
# Claude Code
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install beads-workflow@jtsternberg

# Codex
codex plugin add beads-workflow@jtsternberg
```

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

The names above are the canonical skill names. In Codex, explicit invocation uses `$tackle-epic` or `$fix-findings-beads-tasks`; Claude Code exposes the same plugin skills through its skill interface.
