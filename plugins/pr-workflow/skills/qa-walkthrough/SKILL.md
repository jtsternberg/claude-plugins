---
name: qa-walkthrough
description: Guided manual QA walkthrough for pull requests. Extracts or generates a test plan from PR changes, then walks the user through each test interactively. Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", or wants to manually verify a PR before merge.
---

# QA Walkthrough

Guided manual QA walkthrough that extracts testing steps from a PR, builds a structured beads task list (`bd create`) and epic, and walks the user through each test interactively.

## Arguments

```
/qa-walkthrough [<pr-number-or-url>]
```

- **`<pr-number-or-url>`** (optional) — A PR number or full URL. If omitted, use the current branch's PR.

## Step 1: Gather PR Context

Fetch the PR details and branch changes:

```bash
# Get the PR description and metadata
gh pr view [<number>]

# Get the changed files and diff summary
gh pr diff [<number>] --stat
gh pr diff [<number>]
```

If a HANDOFF.md exists in the working directory, read it and extract any testing notes, known issues, or environmental requirements. Incorporate these into the test plan in Step 2.

## Step 2: Extract Testing Steps

Try the bundled extraction script first:

```bash
bash scripts/extract-test-plan.sh <number>
```

This parses the PR description for common test plan headings (`## Testing`, `## Test Plan`, `## How to Test`, etc.). If the script finds a section, use it as the starting point.

If no testing section exists (exit code 1), analyze the code changes and draft a testing plan. Present it to the user for approval before proceeding.

## Step 3: Evaluate Test Coverage

Review the extracted testing steps against the actual code changes. Consider whether additional tests should be added:

- **Regression tests** — Do the changes touch shared functionality that could break existing behavior?
- **Edge cases** — Are there boundary conditions, empty inputs, or error states not covered?
- **SSO/auth variations** — If the feature interacts with authentication, test both authenticated and unauthenticated flows.
- **Admin UI** — If there are admin-facing changes, verify field rendering, persistence, and data cleanup.

Present any suggested additions to the user. Only add tests the user approves.

## Step 4: Build Beads Epic

Create a beads epic and individual tasks with dependencies.

**Option A — Use the bundled script** (preferred for 3+ tasks):

Build a JSON test plan array and pipe it to the script:

```bash
echo '[
  {"name": "Pre-setup: ...", "description": "...", "depends_on_index": null},
  {"name": "Admin UI: ...", "description": "...", "depends_on_index": 0},
  {"name": "Checkout flow: ...", "description": "...", "depends_on_index": 1}
]' | bash scripts/build-qa-epic.sh <number> "<short description>"
```

The script creates the epic, all tasks, and wires up dependencies in one shot. It returns JSON with the epic and task IDs.

**Option B — Manual creation** (for 1-2 tasks):

```bash
bd create --title="Test PR #<number>: <short description>" --description="Manual testing for PR #<number>" --type=epic --priority=1
```

Group related sub-steps into single tasks (e.g., "Admin UI: field rendering & persistence" rather than separate tasks for each click). Run `bd create` commands in parallel for efficiency.

### Set dependencies (manual creation only)

Reflect the natural testing order:
- Pre-setup/environment tasks are unblocked first
- Admin UI verification before checkout/runtime tests
- Basic functionality before advanced scenarios (e.g., non-SSO before SSO)
- Regression tests can run in parallel after setup
- Edge cases come last

Use `bd dep add <task> <depends-on>` for task-to-task dependencies. Do NOT use `bd dep add` with epics as the target — epics track subtasks differently.

### Show the dependency tree

Display a visual ASCII tree of the tasks and their dependencies to the user before starting. Example:

```
Epic: Test PR #519 (wp-content-d9o)
│
├─ 1. Pre-setup: Stripe webhook & test discount (wp-content-vep)  ← READY
│   │
│   ├─ 2. Admin UI: field rendering & persistence (wp-content-9ux)
│   │   │
│   │   ├─ 3a. Checkout (no SSO): matching email succeeds (wp-content-58v)
│   │   │   ├─ 4a. SSO: allowlisted email succeeds (wp-content-mi1)
│   │   │   └─ 4b. SSO: bypass prevention (wp-content-hm9)
```

## Step 5: Walk Through Tests

Process tasks one at a time following the dependency order:

1. Run `bd ready` to find the next unblocked task
2. Claim it: `bd update <id> --status in_progress`
3. **Explain to the user** what to do — be specific:
   - What page/URL to visit
   - What data to enter
   - What action to take
   - What the expected result is
4. **Wait for the user** to confirm (pass/fail/unexpected behavior)
5. On pass: `bd close <id> --reason="<brief result summary>"`
6. On fail: Stop and investigate. Read the relevant code, diagnose, and either:
   - Fix the code and ask the user to retry
   - Create a new beads bug issue: `bd create --title="..." --description="..." --type=bug --deps discovered-from:<failed-task-id>`
   - Prepare a handoff prompt for another agent to fix the bug. Include:
     - The beads issue ID
     - What the test expected vs. what happened
     - The relevant file(s) and line numbers
     - Steps to reproduce
   Present the prompt to the user so they can paste it into a new Claude Code session.
   After addressing the failure, run `bd ready` again — unblocked tasks that don't depend on the failed test can still proceed.
7. Move to the next ready task

Continue until all tasks are complete.

## Step 6: Cleanup

Once all tasks pass:

1. Close the epic: `bd close <epic-id> --reason="All tests passed"`
2. Ask the user: "All tests passed. Want me to delete the testing epic and tasks? They don't add historical value since there are no code changes."
3. If confirmed:
   ```bash
   bash scripts/qa-cleanup.sh <epic-id>
   ```

## Guidelines

- **One task at a time.** Never move ahead without user confirmation.
- **Be concise in instructions.** Lead with what to do, not why.
- **Adapt to user signals.** A thumbs up or brief confirmation means "pass, move on." A screenshot or detailed response means something needs attention.
- **Don't over-test.** If a test is essentially the same code path as another with different input, suggest combining or skipping with user approval.
- **Pre-setup is a real task.** Environment requirements (webhook forwarding, test data creation, etc.) should be their own task — don't assume the user has everything running.
- **Handle surprises gracefully.** If the user reports behavior that is correct but differs from the test plan's assumptions (e.g., a field being hidden in a certain state), acknowledge it and adjust the test accordingly rather than treating it as a failure.
