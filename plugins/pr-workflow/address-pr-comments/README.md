# Address PR Comments

Address PR review comments — automated resolution or human-in-the-loop drafts. Works in Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install address-pr-comments@jtsternberg

# Codex
codex plugin add address-pr-comments@jtsternberg
```

## Skills

### `address-pr-comments`

Address all pending PR review comments systematically.

Invoke `address-pr-comments` with a PR number or a specific comment URL.

**Workflow:**
1. Fetches all unresolved review comments from the current PR
2. Analyzes each comment and the surrounding code
3. Makes necessary code changes
4. Replies to each addressed comment or review with the outcome
5. Provides summary of changes made

**Prerequisites:**
- Must be run from a branch with an open PR
- GitHub CLI (`gh`) must be installed and authenticated

### `address-pr-comments-human`

Address PR comments with human review before pushing and replying.

Invoke `address-pr-comments-human` with a PR number or a specific comment URL.

**Workflow:**
1. Fetches all unresolved review comments from the specified PR
2. Analyzes each comment and drafts code changes and reply text
3. Presents drafts for your approval before taking action
4. After approval: pushes commits and posts replies

**Prerequisites:**
- GitHub CLI (`gh`) must be installed and authenticated

## Example Usage

Claude Code:

```text
# After making changes based on code review
/address-pr-comments:address-pr-comments

# Same, but approve the drafts before anything is pushed
/address-pr-comments:address-pr-comments-human
```

Codex:

```text
$address-pr-comments:address-pr-comments
$address-pr-comments:address-pr-comments-human
```

## Additional Documentation

- [skills/address-pr-comments/SKILL.md](skills/address-pr-comments/SKILL.md) - Address PR comments and post replies
- [skills/address-pr-comments-human/SKILL.md](skills/address-pr-comments-human/SKILL.md) - Human-in-the-loop PR comment resolution

Part of the pr-workflow bundle — install pr-workflow to get all PR skills at once.
