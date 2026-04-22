# PR Workflow Plugin

Commands and skills for managing pull requests: addressing comments, updating descriptions, and watching PRs for events.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install pr-workflow@jtsternberg
```

## Description

Streamlines common PR workflows with commands for addressing review comments, keeping PR descriptions in sync with code changes, and polling PRs for conditions like Copilot finishing, leaving draft, or receiving a review.

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

### `/address-pr-comments-human`

Address PR comments with human review before pushing and replying.

```
/address-pr-comments-human <pr-number>
```

**Workflow:**
1. Fetches all unresolved review comments from the specified PR
2. Analyzes each comment and drafts code changes and reply text
3. Presents drafts for your approval before taking action
4. After approval: pushes commits and posts replies

**Prerequisites:**
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

## Skills

### `/watch-pr`

Poll a GitHub PR until a condition is met, then execute a follow-up action.

```
/watch-pr <pr-number-or-url> [for <condition>] [then <action>]
```

**Conditions:**
- `copilot` (default) — wait for Copilot to finish work (`copilot_work_finished` event)
- `ready` — wait for PR to leave draft
- `review` — wait for a new review to be submitted

**Examples:**
- `/watch-pr 2165` — wait for Copilot to finish, then review
- `/watch-pr 2165 for ready` — wait for PR to leave draft, then review
- `/watch-pr 2165 for copilot then merge it` — wait for Copilot, then merge
- `/watch-pr https://github.com/org/repo/pull/99 for ready then /address-pr-comments`

**Workflow:**
1. Parses the PR identifier, condition, and optional follow-up action
2. Verifies the PR exists (aborts if closed/merged)
3. Checks condition immediately
4. If not met, schedules a cron job polling every 5 minutes
5. Once condition is met, cancels the cron and executes the follow-up (defaults to `/review-pr <number>`)

**Prerequisites:**
- GitHub CLI (`gh`) must be installed and authenticated

### `/qa-walkthrough`

Guided manual QA walkthrough for a PR — extracts a test plan, builds beads tasks, and walks you through each test one at a time.

```
/qa-walkthrough [<pr-number-or-url>]
```

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

```bash
# After making changes based on code review
/address-pr-comments

# After adding more commits to your PR
/update-pr-description

# Wait for Copilot to finish, then review
/watch-pr 2165

# Wait for a draft PR to be marked ready, then review
/watch-pr 2165 for ready

# QA walkthrough for the current branch's PR
/qa-walkthrough

# QA walkthrough for a specific PR
/qa-walkthrough 519
```

## Additional Documentation

- [commands/address-pr-comments.md](commands/address-pr-comments.md) - Auto-resolve PR comments
- [commands/address-pr-comments-human.md](commands/address-pr-comments-human.md) - Human-in-the-loop PR comment resolution
- [commands/update-pr-description.md](commands/update-pr-description.md) - Update PR description from changes
- [skills/watch-pr/SKILL.md](skills/watch-pr/SKILL.md) - Watch PR for conditions (Copilot, ready, review)
- [skills/qa-walkthrough/SKILL.md](skills/qa-walkthrough/SKILL.md) - Guided manual QA walkthrough
