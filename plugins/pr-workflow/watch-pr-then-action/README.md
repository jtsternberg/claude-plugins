# Watch PR Then Action

Watch a PR for events (CI, reviews, ready-for-review) and run a follow-up action. Works in Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install watch-pr-then-action@jtsternberg

# Codex
codex plugin add watch-pr-then-action@jtsternberg
```

## Skills

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

## Example Usage

Claude Code:

```text
# Wait for Copilot to finish, then review
/watch-pr-then-action:watch-pr-then-action 2165

# Wait for a draft PR to be marked ready, then review
/watch-pr-then-action:watch-pr-then-action 2165 for ready
```

Codex:

```text
$watch-pr-then-action:watch-pr-then-action 2165
```

## Additional Documentation

- [skills/watch-pr-then-action/SKILL.md](skills/watch-pr-then-action/SKILL.md) - Watch PR for conditions (Copilot, ready, review)

Part of the pr-workflow bundle — install pr-workflow to get all PR skills at once.
