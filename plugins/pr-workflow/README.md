# PR Workflow Plugin

Commands for managing pull requests: addressing comments and updating descriptions.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install pr-workflow@jtsternberg
```

## Description

Streamlines common PR workflows with commands for addressing review comments and keeping PR descriptions in sync with code changes.

## Commands

### `/address-pr-comments`

Address all pending PR review comments systematically.

```
/address-pr-comments
```

**Workflow:**
1. Fetches all unresolved review comments from the current PR
2. Analyzes each comment and the surrounding code
3. Makes necessary code changes
4. Marks resolved comments as resolved
5. Provides summary of changes made

**Prerequisites:**
- Must be run from a branch with an open PR
- GitHub CLI (`gh`) must be installed and authenticated

### `/update-pr-description`

Update PR description based on code changes since last edit.

```
/update-pr-description
```

**Workflow:**
1. Analyzes code changes made since the PR description was last updated
2. Reviews the current PR description
3. Generates an updated description reflecting new changes
4. Updates the PR on GitHub

**Prerequisites:**
- Must be run from a branch with an open PR
- GitHub CLI (`gh`) must be installed and authenticated

## Example Usage

```bash
# After making changes based on code review
/address-pr-comments

# After adding more commits to your PR
/update-pr-description
```

## Additional Documentation

- [commands/address-pr-comments.md](commands/address-pr-comments.md) - Complete command documentation
- [commands/update-pr-description.md](commands/update-pr-description.md) - Complete command documentation
