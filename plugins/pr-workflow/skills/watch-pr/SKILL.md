---
name: watch-pr
description: Polls a GitHub PR for a specific condition, then executes a follow-up action. Conditions include waiting for Copilot to finish work, waiting for a draft PR to be marked ready for review, or waiting for someone to submit a review. Use when the user says things like "watch copilot", "wait for copilot", "watch this PR", "let me know when the PR is ready", or "notify me when it's reviewed".
---

# Watch PR

Poll a GitHub PR until a condition is met, then execute a follow-up action.

## Arguments

```
/watch-pr <pr-number-or-url> [for <condition>] [then <action>]
```

- **`<pr-number-or-url>`** (required) — A PR number (e.g., `2165`) or full URL
- **`for <condition>`** (optional) — What to wait for. See [Conditions](#conditions). Defaults to `copilot`.
- **`then <action>`** (optional) — Follow-up prompt or slash command. Defaults to `/review-pr <number>`.

Examples:
- `/watch-pr 2165` — wait for Copilot to finish, then review
- `/watch-pr 2165 for ready` — wait for PR to leave draft, then review
- `/watch-pr 2165 for copilot then merge it` — wait for Copilot, then merge
- `/watch-pr https://github.com/org/repo/pull/99 for ready then /address-pr-comments`

## Conditions

### `copilot` (default)

Wait for GitHub Copilot to finish work. The only reliable signal is the `copilot_work_finished` event in the issue events API.

**Check command:**
```bash
gh api repos/<owner>/<repo>/issues/<number>/events --jq '[.[] | select(.event == "copilot_work_finished")] | length'
```

**Done when:** result > 0

**Waiting message:** `"PR #<number>: Copilot still working. Will check again in 5 minutes."`

**Done message:** `"Copilot has finished work on PR #<number>."`

### `ready`

Wait for a PR to be marked ready for review (moved out of draft). Use when someone has a draft PR and you want to act once they put it up for review.

**Check command:**
```bash
gh pr view <number> --repo <owner/repo> --json isDraft --jq '.isDraft'
```

**Done when:** result is `false`

**Waiting message:** `"PR #<number>: Still in draft. Will check again in 5 minutes."`

**Done message:** `"PR #<number> is now ready for review."`

### `review`

Wait for a new review to be submitted on the PR (approval, changes requested, or comment).

**Check command:**
```bash
gh api repos/<owner>/<repo>/pulls/<number>/reviews --jq 'length'
```

Store the initial count on first check. Done when the count increases.

**Waiting message:** `"PR #<number>: No new reviews yet. Will check again in 5 minutes."`

**Done message:** `"PR #<number> has received a new review."`

## Workflow

### Step 1: Parse Input

1. Split input on ` for ` and ` then ` (case-insensitive) to extract: PR identifier, condition, and action
2. Defaults: condition → `copilot`, action → `/review-pr <number>`
3. Accept PR number or full URL. For a number, detect repo via `gh repo view --json nameWithOwner -q .nameWithOwner`. For a URL, extract owner/repo/number from the path.
4. If no argument provided, prompt for a PR number or URL.

### Step 2: Verify the PR Exists

```bash
gh pr view <number> --repo <owner/repo> --json title,isDraft,state
```

Confirm it exists and report its title and state. If the PR is closed or merged, abort with a message.

### Step 3: Check Condition Immediately

Run the condition's check command once. If already met, skip to Step 5.

### Step 4: Schedule Recurring Poll

Use CronCreate to poll every 5 minutes:

- **Cron expression:** `*/5 * * * *`
- **Recurring:** `true`
- **Prompt:**

```
Check PR #<number> in <owner/repo> for condition "<condition>".
Run: <check command>
If done: cancel cron job <job-id> using CronDelete, then execute: <action>
If not done: report "<waiting message>"
```

Report the cron job ID so the user can cancel manually if needed.

### Step 5: Execute Follow-Up

1. Cancel the cron job (if one was scheduled)
2. Report the condition's done message
3. Execute the follow-up action
