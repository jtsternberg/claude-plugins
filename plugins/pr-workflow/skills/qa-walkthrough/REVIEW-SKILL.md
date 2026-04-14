# QA Walkthrough Skill Review (vs Official Docs)

**Date**: 2026-04-14
**Skill**: `plugins/pr-workflow/skills/qa-walkthrough/SKILL.md`
**Reference**: https://code.claude.com/docs/en/skills.md (fetched same day)

## Summary

The skill is well-structured with clear step-by-step instructions and good use of bundled scripts. The recent multi-mode update (PR/branch/ad-hoc) broadens usability significantly. However, comparing against the official skills documentation reveals several concrete improvement opportunities — particularly around frontmatter features, dynamic context injection, compaction resilience, and argument handling.

## Issues

### 1. Missing `argument-hint` frontmatter (P1 — discoverability)

The official docs describe an `argument-hint` field that shows during autocomplete:

> `argument-hint`: Hint shown during autocomplete to indicate expected arguments. Example: `[issue-number]` or `[filename] [format]`.

The skill accepts multiple argument forms but provides no hint. Users typing `/qa-walkthrough` see no guidance about what to pass.

**Recommendation** — add to frontmatter:

```yaml
argument-hint: "[<pr-number> | --branch [--base=<ref>] | --describe \"...\"]"
```

### 2. Missing `when_to_use` field (P2 — trigger accuracy)

The official docs provide a dedicated `when_to_use` field:

> Additional context for when Claude should invoke the skill, such as trigger phrases or example requests. Appended to `description` in the skill listing.

Currently, trigger phrases are crammed into `description`. Splitting them improves both readability and Claude's matching:

**Current:**
```yaml
description: Guided manual QA walkthrough for PRs, branch changes, or ad-hoc testing. Generates a test plan, builds a beads epic, and walks the user through each test interactively. Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", "QA my changes", or wants to manually verify work.
```

**Recommended:**
```yaml
description: Guided manual QA walkthrough for PRs, branch changes, or ad-hoc testing. Generates a test plan, builds a beads epic, and walks the user through each test interactively.
when_to_use: Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", "QA my changes", "test my changes", or wants to manually verify work before merging or pushing.
```

### 3. No `$ARGUMENTS` substitution (P1 — argument handling)

The official docs show that `$ARGUMENTS`, `$ARGUMENTS[N]`, and `$N` are substituted before Claude sees the skill content. The skill currently describes arguments in a documentation block and expects Claude to parse them from context. Using native substitution would be more reliable:

**Recommendation** — add an argument routing section that uses `$ARGUMENTS` directly:

```markdown
## Input

Arguments: $ARGUMENTS
```

This ensures the raw argument string is always visible in the rendered skill content, even if Claude doesn't parse the `/qa-walkthrough --branch` invocation perfectly. Claude can then match `$ARGUMENTS` against the mode table in Step 0.

### 4. No `${CLAUDE_SKILL_DIR}` for script paths (P2 — portability)

The skill references scripts as `bash scripts/extract-test-plan.sh`, which is relative to the working directory. The official docs provide `${CLAUDE_SKILL_DIR}`:

> The directory containing the skill's `SKILL.md` file. Use this in bash injection commands to reference scripts or files bundled with the skill, regardless of the current working directory.

If the user invokes this skill from a subdirectory, the relative `scripts/` path will break.

**Recommendation** — replace all `bash scripts/` references with:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/extract-test-plan.sh" <args>
```

This is the single most impactful reliability fix.

### 5. No dynamic context injection via `!` syntax (P2 — auto-detect mode)

The official docs describe `` !`command` `` preprocessing that runs before Claude sees the content:

> The `` !`<command>` `` syntax runs shell commands before the skill content is sent to Claude. The command output replaces the placeholder.

Step 0's auto-detection logic (checking `gh pr view` to decide mode) could be done at injection time, giving Claude the answer instead of asking it to figure it out:

**Recommendation** — add a dynamic context block near the top of the skill:

```markdown
## Auto-detected context
- Current branch: !`git branch --show-current 2>/dev/null || echo "detached"`
- Has PR: !`gh pr view --json number -q .number 2>/dev/null || echo "none"`
- Uncommitted changes: !`git status --porcelain 2>/dev/null | head -5`
```

This gives Claude the facts upfront instead of requiring it to run commands to determine mode. The mode decision table in Step 0 still applies — it just has data to work with immediately.

### 6. No compaction resilience (P2 — long sessions)

The official docs describe how skills survive compaction:

> Auto-compaction carries invoked skills forward within a token budget. [...] re-attaches the most recent invocation of each skill after the summary, keeping the first 5,000 tokens of each.

This skill is ~208 lines. After compaction, only the first ~5,000 tokens survive. The dependency tree, current task state, and remaining test plan will be lost. The previous REVIEW.md suggested a progress checklist for this reason.

**Recommendation** — add a note in the Guidelines section:

```markdown
- **Compaction resilience.** If context compresses mid-walkthrough, run `bd ready` to
  recover state. The beads epic and task structure persist independently of the conversation.
  Re-invoke `/qa-walkthrough` if the skill instructions feel absent after compaction.
```

The beads structure is the resilience mechanism here — the skill should call that out explicitly so Claude (or the user) knows how to recover.

### 7. `disable-model-invocation` should be considered (P3 — invocation control)

The official docs explain:

> `disable-model-invocation: true`: Only you can invoke the skill. Use for workflows with side effects or that you want to control timing.

This skill creates beads epics and tasks (side effects). It's unlikely a user wants Claude to spontaneously decide to run a QA walkthrough. Adding `disable-model-invocation: true` would prevent accidental invocation while keeping `/qa-walkthrough` available.

**Counter-argument:** A user saying "QA my changes" should trigger this automatically. The current behavior is probably correct for this skill's use case. But it's worth documenting the decision.

### 8. Consider `context: fork` for the gathering phase (P3 — context isolation)

The official docs describe forked execution:

> Add `context: fork` to your frontmatter when you want a skill to run in isolation.

The full skill shouldn't fork (it needs interactive back-and-forth), but Steps 1-2 (gathering context, analyzing diffs) could benefit from a subagent to avoid polluting the main context with large diffs. This is an architectural consideration, not a bug — the current approach works fine for most PRs.

### 9. `allowed-tools` could pre-approve common tools (P3 — permission friction)

The official docs show:

> The `allowed-tools` field grants permission for the listed tools while the skill is active.

During a QA walkthrough, Claude will run `gh`, `git`, `bd`, and `bash scripts/*` repeatedly. Pre-approving these reduces permission prompts:

```yaml
allowed-tools: Bash(gh *) Bash(git diff *) Bash(git status *) Bash(git branch *) Bash(bd *) Bash(bash scripts/*)
```

### 10. Script paths should use `${CLAUDE_SKILL_DIR}` in code blocks (P1 — correctness)

Related to issue #4 but specific: every `bash scripts/` in a code block that Claude might execute should use the full substitution path. Currently there are 5 such references:

- Line 54: `bash scripts/extract-test-plan.sh --from-diff`
- Line 76: `bash scripts/extract-test-plan.sh <number>`
- Line 122: `bash scripts/build-qa-epic.sh "$QA_LABEL" "<short description>"`
- Line 197: `bash scripts/qa-cleanup.sh <epic-id>`

All should become `bash "${CLAUDE_SKILL_DIR}/scripts/..."`.

### 11. `effort` field could improve test plan quality (P4 — nice-to-have)

The docs mention:

> `effort`: Effort level when this skill is active. Options: `low`, `medium`, `high`, `max`.

QA walkthroughs benefit from thorough analysis. Setting `effort: high` would encourage more careful test plan generation without requiring Opus 4.6's `max`.

## Recommendations (Prioritized)

1. **Use `${CLAUDE_SKILL_DIR}` for all script paths** (P1 — will break if invoked from subdirectory)
2. **Add `argument-hint`** (P1 — zero-cost discoverability win)
3. **Add `$ARGUMENTS` substitution** (P1 — more reliable argument passing)
4. **Split `when_to_use` from `description`** (P2 — cleaner trigger matching)
5. **Add `!` dynamic context injection** (P2 — pre-populate mode detection data)
6. **Add compaction resilience guidance** (P2 — prevents mid-walkthrough confusion)
7. **Add `allowed-tools`** (P3 — reduces permission friction)
8. **Document `disable-model-invocation` decision** (P3 — intentional choice)
9. **Consider `effort: high`** (P4 — marginal quality improvement)

## Quick Wins (can be applied in one pass)

```yaml
---
name: qa-walkthrough
description: Guided manual QA walkthrough for PRs, branch changes, or ad-hoc testing. Generates a test plan, builds a beads epic, and walks the user through each test interactively.
when_to_use: Use when the user says "QA this PR", "qa walkthrough", "manual testing", "walk me through testing", "QA my changes", "test my changes", or wants to manually verify work before merging or pushing.
argument-hint: "[<pr-number> | --branch | --describe \"...\"]"
allowed-tools: Bash(gh *) Bash(git *) Bash(bd *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/*")
---
```
