# PR Workflow Plugin

Skills for managing pull requests: addressing comments, updating descriptions, and watching PRs for events. All workflows work in Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install pr-workflow@jtsternberg

# Codex
codex plugin add pr-workflow@jtsternberg
```

## Description

Streamlines common PR workflows for addressing review comments, keeping PR descriptions in sync with code changes, and polling PRs for conditions like Copilot finishing, leaving draft, or receiving a review.

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

### `watch-pr-then-action`

Poll a GitHub PR until a condition is met, then execute a follow-up action.

Invoke `watch-pr-then-action` with a PR number or URL, an optional condition, and an optional follow-up action.

**Conditions:**
- `copilot` (default) — wait for Copilot to finish work (`copilot_work_finished` event)
- `ready` — wait for PR to leave draft
- `review` — wait for a new review to be submitted

**Examples:**
- `watch-pr-then-action 2165` — wait for Copilot to finish, then review
- `watch-pr-then-action 2165 for ready` — wait for PR to leave draft, then review
- `watch-pr-then-action 2165 for copilot then merge it` — wait for Copilot, then merge
- `watch-pr-then-action https://github.com/org/repo/pull/99 for ready then address the PR comments`

**Workflow:**
1. Parses the PR identifier, condition, and optional follow-up action
2. Verifies the PR exists (aborts if closed/merged)
3. Checks condition immediately
4. If not met, schedules a cron job polling every 5 minutes
5. Once condition is met, cancels the cron and executes the follow-up (defaults to `review PR <number>`)

**Prerequisites:**
- GitHub CLI (`gh`) must be installed and authenticated

### `qa-walkthrough-pr`

Guided manual QA walkthrough for a PR — extracts a test plan, builds beads tasks, and walks you through each test one at a time.

Invoke `qa-walkthrough-pr` with an optional PR number or URL.

**Workflow:**
1. Gathers PR context (description, diff, HANDOFF.md if present)
2. Extracts testing steps from the PR description (or drafts a plan from the code changes)
3. Evaluates test coverage and suggests additional cases
4. Builds a beads epic with dependent tasks reflecting the testing order
5. Walks through each test interactively — one at a time, waiting for pass/fail
6. On failure: creates a bug issue with `discovered-from` linking and prepares a handoff prompt for another agent
7. Cleans up the QA epic and tasks after all tests pass

**Bundled scripts:**
- `extract-test-plan.sh` — deterministic test section extraction from PR description
- `build-qa-epic.sh` — creates epic + tasks + deps from a JSON plan in one shot
- `qa-cleanup.sh` — safe cleanup of QA artifacts with `--dry-run` support

**Prerequisites:**
- GitHub CLI (`gh`) must be installed and authenticated
- [beads](https://github.com/jtsternberg/beads) (`bd`) must be installed

## Example Usage

Use the canonical skill names above when describing the workflow to either harness. For explicit invocation, use `/pr-workflow:address-pr-comments` or `/pr-workflow:qa-walkthrough-pr` in Claude Code, and `$address-pr-comments` or `$qa-walkthrough-pr` in Codex. The slash and dollar-sign forms are harness syntax, not part of the skill names.

## Additional Documentation

- [skills/address-pr-comments/SKILL.md](skills/address-pr-comments/SKILL.md) - Address PR comments and post replies
- [skills/address-pr-comments-human/SKILL.md](skills/address-pr-comments-human/SKILL.md) - Human-in-the-loop PR comment resolution
- [skills/update-pr-description/SKILL.md](skills/update-pr-description/SKILL.md) - Update PR description from changes
- [skills/watch-pr-then-action/SKILL.md](skills/watch-pr-then-action/SKILL.md) - Watch PR for conditions (Copilot, ready, review)
- [skills/qa-walkthrough-pr/SKILL.md](skills/qa-walkthrough-pr/SKILL.md) - Guided manual QA walkthrough
