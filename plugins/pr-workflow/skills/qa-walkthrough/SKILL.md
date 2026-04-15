---
name: qa-walkthrough
description: Guided manual QA walkthrough for PRs, branch changes, or ad-hoc testing. Generates a test plan, builds a beads epic, and walks the user through each test interactively.
when_to_use: Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", "QA my changes", "test my changes", or wants to manually verify work before merging or pushing.
argument-hint: "[<pr-number> | --branch | --describe \"...\"]"
allowed-tools: Bash(gh *) Bash(git *) Bash(bd *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/*")
effort: high
---

# QA Walkthrough

<!-- Note: disable-model-invocation is intentionally NOT set. While this skill creates beads
     epics (a side effect), users expect "QA my changes" to trigger it automatically.
     Reviewed 2026-04-14 against official skills docs. -->

Guided manual QA walkthrough that generates a test plan from a PR, branch diff, or description, builds a structured beads task list (`bd create`) and epic, and walks the user through each test interactively.

## Arguments

```
/qa-walkthrough [<pr-number-or-url>]
/qa-walkthrough --branch [--base=<ref>]
/qa-walkthrough --describe "<what to test>"
```

- **`<pr-number-or-url>`** (optional) — A PR number or full URL. If omitted with no flags, use the current branch's PR.
- **`--branch`** — QA uncommitted or branch changes via git diff instead of a PR.
- **`--base=<ref>`** — Base ref for branch mode (default: `main`).
- **`--describe "<text>"`** — QA from a description (e.g., testing a new skill, config change, or plugin).

**Input:** $ARGUMENTS

## Auto-detected context

- Current branch: !`git branch --show-current 2>/dev/null || echo "detached"`
- Has PR: !`gh pr view --json number -q .number 2>/dev/null || echo "none"`
- Uncommitted changes: !`git status --porcelain 2>/dev/null | head -5`

## Step 0: Determine Mode

Detect the mode from arguments:

| Arguments | Mode | Source |
|-----------|------|--------|
| `<pr-number-or-url>` or no args (and current branch has a PR) | **PR** | `gh pr view` / `gh pr diff` |
| `--branch` or no args (and current branch has NO PR) | **Branch** | `git diff` (staged + branch vs base) |
| `--describe "..."` | **Ad-hoc** | User-provided description |

If no arguments are given, auto-detect: check `gh pr view --json number -q .number 2>/dev/null`. If that returns a number, use PR mode. Otherwise, fall back to branch mode.

## Step 1: Gather Context

### PR Mode

```bash
# Get the PR description and metadata
gh pr view [<number>]

# Get the changed files and diff summary
gh pr diff [<number>] --stat
gh pr diff [<number>]
```

Set `QA_LABEL="PR #<number>"`.

### Branch Mode

```bash
# Get the diff summary and changes
bash "${CLAUDE_SKILL_DIR}/scripts/extract-test-plan.sh" --from-diff[=<base-ref>]
```

Set `QA_LABEL` to the branch name (`git branch --show-current`).

### Ad-hoc Mode

The user's description is the context. No code diff needed — you'll generate the test plan from the description alone.

Set `QA_LABEL` to a short slug from the description (e.g., "new-skill-qa-walkthrough").

---

In all modes: if a HANDOFF.md exists in the working directory, read it and extract any testing notes, known issues, or environmental requirements. Incorporate these into the test plan in Step 2.

## Step 2: Extract Testing Steps

### PR Mode

Try the bundled extraction script first:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/extract-test-plan.sh" <number>
```

This parses the PR description for common test plan headings (`## Testing`, `## Test Plan`, `## How to Test`, etc.). If the script finds a section, use it as the starting point.

If no testing section exists (exit code 1), analyze the code changes and draft a testing plan.

### Branch Mode

The diff output from Step 1 is your source. Analyze the changed files and draft a testing plan based on what was modified.

### Ad-hoc Mode

Use the user's description to generate a testing plan. Focus on:
- The described feature's expected behavior
- Edge cases and error states
- Integration points with existing functionality

---

In all modes: present the test plan to the user for approval before proceeding.

## Step 3: Evaluate Test Coverage

Review the extracted testing steps against the actual changes (if any). Consider whether additional tests should be added:

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
]' | bash "${CLAUDE_SKILL_DIR}/scripts/build-qa-epic.sh" "$QA_LABEL" "<short description>"
```

The script creates the epic, all tasks, and wires up dependencies in one shot. It returns JSON with the epic and task IDs.

**Option B — Manual creation** (for 1-2 tasks):

```bash
bd create --title="QA: $QA_LABEL — <short description>" --description="Manual QA walkthrough for $QA_LABEL" --type=epic --priority=1
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
Epic: QA: feature-branch — new checkout flow (wp-content-d9o)
|
|- 1. Pre-setup: Stripe webhook & test discount (wp-content-vep)  <- READY
|   |
|   |- 2. Admin UI: field rendering & persistence (wp-content-9ux)
|   |   |
|   |   |- 3a. Checkout (no SSO): matching email succeeds (wp-content-58v)
|   |   |   |- 4a. SSO: allowlisted email succeeds (wp-content-mi1)
|   |   |   +- 4b. SSO: bypass prevention (wp-content-hm9)
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
6. On fail: **Create a fix task and let the user decide priority:**
   a. Create a beads bug linked to the failed test:
      ```bash
      bd create --title="Fix: <what failed>" \
        --description="<what was expected vs. what happened, steps to reproduce, relevant files/lines>" \
        --type=bug --priority=1 \
        --deps discovered-from:<failed-task-id>
      ```
   b. Mark the QA task as failed (do NOT close it):
      ```bash
      bd update <qa-task-id> --notes="FAILED: <brief description of failure>"
      ```
   c. **Ask the user one question:**
      > This test failed. I've created `<bug-id>` to track the fix. Should I work on this fix now before continuing QA, or continue testing and address all failures after the walkthrough?
   d. **If "fix now":** Work on the fix. Once resolved, close the bug (`bd close <bug-id>`), then ask the user to re-test the original QA step. On re-test pass, close the QA task. On re-test fail, repeat from (a).
   e. **If "continue QA":** Leave the bug open and move on. After addressing the failure, run `bd ready` again — unblocked tasks that don't depend on the failed test can still proceed. Tasks that depend on the failed test remain blocked.
7. Move to the next ready task

Continue until all passable tasks are complete. If any failures were punted, proceed to Step 5b.

### Step 5b: Resolve Punted Failures

If any failures were deferred during the walkthrough:

1. List all open bugs discovered during QA:
   ```bash
   bd list --status=open --type=bug
   ```
   Filter to bugs with `discovered-from` links to this QA epic's tasks.
2. Present the list to the user with a summary of each failure.
3. Work through each bug one at a time:
   a. Claim it: `bd update <bug-id> --claim`
   b. Fix the code
   c. Ask the user to re-verify the original QA step
   d. On pass: close both the bug and the original QA task
   e. On fail: update the bug with new findings and ask the user how to proceed
4. Once all bugs are resolved (or the user decides to stop), continue to Step 6.

## Step 6: Cleanup

Once all QA tasks and any punted bugs are resolved:

1. Close the epic: `bd close <epic-id> --reason="All tests passed"`
2. Ask the user: "All tests passed. Want me to delete the testing epic and tasks? They don't add historical value since there are no code changes."
3. If confirmed:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/qa-cleanup.sh" <epic-id>
   ```

If the user decides to stop before all bugs are resolved, do NOT close the epic. Leave it open with a note summarizing the remaining failures so the next session can pick up where this one left off:

```bash
bd update <epic-id> --notes="QA incomplete — <N> bugs remain open: <bug-id-1>, <bug-id-2>, ..."
```

## Guidelines

- **One task at a time.** Never move ahead without user confirmation.
- **Be concise in instructions.** Lead with what to do, not why.
- **Adapt to user signals.** A thumbs up or brief confirmation means "pass, move on." A screenshot or detailed response means something needs attention.
- **Don't over-test.** If a test is essentially the same code path as another with different input, suggest combining or skipping with user approval.
- **Pre-setup is a real task.** Environment requirements (webhook forwarding, test data creation, etc.) should be their own task — don't assume the user has everything running.
- **Handle surprises gracefully.** If the user reports behavior that is correct but differs from the test plan's assumptions (e.g., a field being hidden in a certain state), acknowledge it and adjust the test accordingly rather than treating it as a failure.
- **Compaction resilience.** If context compresses mid-walkthrough, run `bd ready` to recover state. The beads epic and task structure persist independently of the conversation. Re-invoke `/qa-walkthrough` if the skill instructions feel absent after compaction.
