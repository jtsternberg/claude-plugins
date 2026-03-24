# QA Walkthrough Skill Review

**Date**: 2025-03-23
**Skill**: `plugins/pr-workflow/skills/qa-walkthrough/SKILL.md`

## Summary

Well-structured interactive skill with clear step-by-step workflow, but the description is doing too much work (risks hitting the 1024-char limit), there's a hardcoded dependency on project-specific CLI tools, and several opportunities exist to improve reliability via scripts and validation loops.

## Issues

### 1. Description approaching max length (line 3)

The `description` field is ~391 characters — well within the 1024 limit, but it's front-loaded with implementation detail ("creates a beads epic with dependent tasks") that belongs in the body. The description should focus on **what** and **when**, not **how**.

**Current** (line 3):
```yaml
description: Guided manual QA walkthrough for pull requests. Extracts testing steps from a PR description, suggests additional test cases, creates a beads epic with dependent tasks, then walks the user through each test one at a time. Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", "qa-walkthrough", or wants to manually verify a PR before merge.
```

**Recommended**:
```yaml
description: Guided manual QA walkthrough for pull requests. Extracts or generates a test plan from PR changes, then walks the user through each test interactively. Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", or wants to manually verify a PR before merge.
```

### 2. Hardcoded project-specific CLI tools (lines 27-28)

```bash
./bin/monorepo/pr-description-generator --smart --base=$(./bin/monorepo/gh-get-base-pr-branch.sh)
```

These paths are specific to a particular repo. If the skill is invoked in a project without these scripts, it will fail silently or confusingly. Per best practices: **scripts should handle errors explicitly, not punt to Claude**.

**Recommendation**: Add a guard or make this conditional:
```bash
# Get branch changes
if [ -x ./bin/monorepo/pr-description-generator ]; then
  ./bin/monorepo/pr-description-generator --smart --base=$(./bin/monorepo/gh-get-base-pr-branch.sh)
else
  # Fallback: use gh + git diff for context
  gh pr diff [<number>] --stat
  git diff $(gh pr view [<number>] --json baseRefName -q .baseRefName)...HEAD --stat
fi
```

Or simply replace the monorepo-specific command with the universal `gh pr diff` approach entirely, since this is a shared plugin.

### 3. HANDOFF.md reference is vague (line 30)

> Also check for a HANDOFF.md in the working directory and incorporate if present.

This tells Claude *that* it should check, but not *what* to look for or *how* to incorporate it. Claude will likely just dump the whole file into context. Per best practices on degrees of freedom: this is a case where medium freedom with a hint would be better.

**Recommendation**:
```markdown
If a HANDOFF.md exists in the working directory, read it and extract any testing notes,
known issues, or environmental requirements. Incorporate these into the test plan in Step 2.
```

### 4. Missing validation/feedback loop (Steps 2-3)

The skill generates a test plan and suggests additions, but there's no structured validation. Per best practices, complex workflows benefit from a **plan-validate-execute** pattern.

**Recommendation**: After Step 3, add an explicit confirmation gate:
```markdown
## Step 3b: Confirm Test Plan

Present the complete, numbered test plan to the user in a single message. Format:

1. [Test name] — [one-line description of what to verify]
2. ...

Ask: "Does this test plan look complete? Add/remove/reorder anything?"

Only proceed to Step 4 after explicit user approval.
```

### 5. `bd delete` with `--force` is risky (line 123)

```bash
bd delete <all-task-ids> <epic-id> --force
```

Using `--force` bypasses confirmation. While the skill asks the user first (line 120), Claude might misinterpret a casual response as confirmation. Better to omit `--force` and let `bd delete` confirm naturally, or explicitly validate the user's response.

### 6. No checklist pattern (best practice recommendation)

The best practices docs strongly recommend providing a **copyable checklist** for multi-step workflows. This skill has 6 steps but no checklist. Adding one improves tracking, especially if context compresses mid-walkthrough.

**Recommendation** — add after the intro paragraph (line 8):
```markdown
## Progress Checklist

Copy this checklist and update as you progress:

```
QA Walkthrough Progress:
- [ ] Step 1: Gather PR context
- [ ] Step 2: Extract testing steps
- [ ] Step 3: Evaluate test coverage
- [ ] Step 4: Build beads epic and tasks
- [ ] Step 5: Walk through all tests
- [ ] Step 6: Cleanup
```
```

### 7. Third-person description (best practice)

Per the docs: *"Always write in third person."* The description says "Use when the user says..." which is second-person addressing Claude. This is actually fine for Claude Code skills (the docs target API/claude.ai skills), but noting for completeness.

### 8. Step 5 doesn't handle partial failure well (lines 108-110)

When a test fails, the skill says to "Stop and investigate. Read the relevant code, diagnose, and either fix or create a bug." But it doesn't say what happens to the **remaining tests** — should they continue or abort? Some tests may not depend on the failed one.

**Recommendation** — add after line 110:
```markdown
   - After addressing the failure, run `bd ready` again — unblocked tasks that don't
     depend on the failed test can still proceed. Only block the dependency chain.
```

## Recommendations (Prioritized)

1. **Remove hardcoded monorepo paths** (P1 — portability blocker). Replace with `gh pr diff` fallback or universal approach.
2. **Add test plan confirmation gate** (P1 — quality). Explicit user sign-off before building beads structure.
3. **Add progress checklist** (P2 — resilience). Helps survive context compression.
4. **Tighten description** (P2 — discovery). Remove implementation detail, keep trigger words.
5. **Handle partial test failures** (P2 — completeness). Continue unblocked tests after failure.
6. **Clarify HANDOFF.md usage** (P3 — clarity). Tell Claude what to extract and how.
7. **Remove `--force` from delete** (P3 — safety). Let bd confirm naturally.

## Script Opportunities

### 1. `scripts/extract-test-plan.sh` — Parse PR description for test sections

```bash
#!/bin/bash
# Extract testing section from PR description
# Usage: extract-test-plan.sh <pr-number>
PR=${1:?Usage: extract-test-plan.sh <pr-number>}
gh pr view "$PR" --json body -q .body | \
  sed -n '/^## \(Testing\|Test Plan\|How to Test\|Manual Testing\|Testing Procedure\)/,/^## /p' | \
  head -n -1
```

This would make Step 2 more reliable — a script extracts the section deterministically, then Claude only needs to interpret it. Follows the best practice of preferring scripts for deterministic operations.

### 2. `scripts/build-qa-epic.sh` — Create beads epic + tasks from a test plan JSON

Rather than having Claude run N sequential `bd create` + `bd dep add` commands (error-prone), a single script could accept a JSON test plan and create the full beads structure atomically:

```bash
#!/bin/bash
# Usage: build-qa-epic.sh <pr-number> < test-plan.json
# Input: JSON array of {name, description, depends_on_index}
# Output: JSON with created task IDs and dependency map
```

This implements the **verifiable intermediate output** pattern: Claude generates a JSON plan, the script validates and creates everything, and returns the result. Much more reliable than Claude running 10+ individual commands.

### 3. `scripts/qa-cleanup.sh` — Safe cleanup of QA artifacts

```bash
#!/bin/bash
# Usage: qa-cleanup.sh <epic-id>
# Lists all tasks under the epic, confirms, then deletes
EPIC=${1:?Usage: qa-cleanup.sh <epic-id>}
echo "Tasks to delete:"
bd list --epic="$EPIC" --format=short
read -p "Delete all? (y/N) " confirm
[[ "$confirm" == "y" ]] && bd delete $(bd list --epic="$EPIC" -q) "$EPIC" --force
```

Replaces the manual `--force` delete with a script that shows what will be deleted first.
