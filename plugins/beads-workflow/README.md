# Beads Workflow Plugin

This plugin provides the `/tackle-epic` command for working through beads epics.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install beads-workflow@jtsternberg
```

## Dependencies

This plugin requires [beads](https://github.com/steveyegge/beads) to be installed and configured:

```bash
# Install beads
npm install -g @beads/cli

# Or follow installation instructions at:
# https://github.com/steveyegge/beads
```

## Usage

```
/tackle-epic <epic-id> [--here]
```

- **Default:** Creates a new worktree and branch for the epic, then works through all sub-tasks and opens a PR when complete.
- **`--here`:** Work on the current branch in the current directory instead of creating a worktree.
