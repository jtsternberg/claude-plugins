# Update PR Description

Regenerate a pull request's description from its current diff and commits. Works in Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install update-pr-description@jtsternberg

# Codex
codex plugin add update-pr-description@jtsternberg
```

## Skills

### `update-pr-description`

Update a PR description from branch changes, optionally starting at a date or commit.

Invoke `update-pr-description` with an optional date, commit hash, or `--force`.

**Workflow:**
1. Analyzes code changes from the supplied date or commit, or from the PR base branch by default
2. Reviews the current PR description
3. Generates an updated description reflecting new changes
4. Updates the PR on GitHub

**Prerequisites:**
- Must be run from a branch with an open PR
- GitHub CLI (`gh`) must be installed and authenticated

## Example Usage

Claude Code:

```text
# After adding more commits to your PR
/update-pr-description:update-pr-description
```

Codex:

```text
$update-pr-description:update-pr-description
```

## Additional Documentation

- [skills/update-pr-description/SKILL.md](skills/update-pr-description/SKILL.md) - Update PR description from changes

Part of the pr-workflow bundle — install pr-workflow to get all PR skills at once.
