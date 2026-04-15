---
name: review-skill
description: "Review a skill for improvement opportunities against best practices"
argument-hint: "<skill-name-or-path>"
disable-model-invocation: true
effort: max
allowed-tools: Read Glob Grep Bash Write Edit
---

Your job will be to review the skill at `$ARGUMENTS` for improvement opportunities.

Look for the skill at the provided path, or in `.claude/skills/$ARGUMENTS/` or `.claude/skills/monorepo-$ARGUMENTS/`.

## Current Skills Documentation

Skills docs cached at: !`bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh`

Read the docs from that path. If the path doesn't exist or the file is empty, tell the user the docs URL is unreachable and stop.

## Step 1: Read the Skill

Read SKILL.md and all bundled files/scripts/etc at the skill path.

Key areas to emphasize:
1. **Inject dynamic context**: Does this skill hardcode context that could be dynamic? Check for opportunities to use `!`command`` syntax (single-line) or ` ```! ` fenced blocks (multi-line) to inject runtime context — current date, git branch, environment info, project metadata, etc. These run at skill load time and inline the output before Claude sees the prompt. Flag any static values that would be more accurate or useful if computed on the fly. This is a great way to reduce the size of the skill and make it more maintainable.
2. **Script opportunities**: Bash/sh scripts that could improve reliability and save on tokens.
3. **`when_to_use` frontmatter**: Is the `description` doing double duty as both a summary and a list of trigger phrases? If so, the trigger phrases should move to `when_to_use` to keep the description focused. Both fields are concatenated for matching (capped at 1,536 chars combined). (This is not relevant for `disable-model-invocation: true` skills)
4. **Skill size & compaction**: Is SKILL.md over 500 lines? Could reference material move to supporting files? If the skill is large and expected to stay active, are critical instructions front-loaded (only first 5,000 tokens survive compaction)?
5. **Invocation control**: Does `disable-model-invocation` / `user-invocable` match the skill's purpose? Side-effect workflows should be user-only. Background knowledge should be model-only.
6. **Tool permissions**: Are `allowed-tools` entries scoped with patterns (e.g., `Bash(git *)`) or overly broad (bare `Bash`)?
7. **String substitutions**: Is the skill using ARGUMENTS, CLAUDE_SKILL_DIR, CLAUDE_SESSION_ID variables where they'd add value?
8. **Subagent execution**: Does the skill use `context: fork` when it shouldn't (needs conversation context or interactive follow-up), or skip it when it should (self-contained task that doesn't need history)? `context: fork` always forks — it's a directive, not a hint. The skill content becomes the subagent's prompt with no conversation history.

## Step 2: Understand Intent, Then Evaluate

ultrathink

Before evaluating anything, determine what this skill is *meant to do* and *how it's meant to be used*. Read the frontmatter, the description, the instructions, and think about:

- **Is this a rigid workflow or a flexible guide?** A deploy skill should be deterministic. A brainstorming skill should leave room for judgment. A review skill falls somewhere in between.
- **Who invokes it and how?** User-only (`disable-model-invocation`)? Model-invocable? Does it take structured arguments or freeform input?
- **What design trade-offs has the author made?** If something looks suboptimal, consider that it might be solving a problem you haven't identified yet. Understand the reasoning before critiquing the result.

If the skill's intent isn't clear from reading it, ask the user before proceeding.

**Now evaluate** — compare against fetched documentation. Focus solely on actionable improvements — no praise or congratulations. Let your understanding of the skill's intent guide which recommendations are appropriate.

Extract key recommendations for: progressive disclosure, utility scripts, validation loops, metadata, frontmatter validation, content organization, inline script execution, and new patterns.

1. **Summary**: Quick assessment (1-2 sentences)
2. **Issues**: Problems with specific line references
3. **Recommendations**: Prioritized improvements with code/text examples

Output the review as a markdown file at `/tmp/skill-review-{skill-name}.md`.

## Step 3: Challenge Your Review

ultrathink

Re-read your review against the docs and the skill. For each recommendation, ask:

- **Does this actually apply to this skill?** Don't recommend patterns that solve problems the skill doesn't have.
- **Is this solving a real problem or a hypothetical one?** If you can't point to a concrete failure mode, cut it.
- **Did you fabricate any metrics?** If a claim includes a number or percentage, show how you measured it. If you can't, cut the number.
- **Are you recommending against a deliberate design choice?** Before saying "replace X with Y," ask why X was chosen. The current approach may exist to solve a problem your recommendation reintroduces.
- **Are you framing flexibility as a bug?** Revisit the intent you identified in Step 2. If the skill intentionally leaves room for Claude to use judgment or conversation context, don't recommend locking it down.
- **Did you miss anything?** Re-scan the docs for patterns the skill could benefit from that you didn't catch in Step 2.

Update the review file — remove recommendations that don't hold up, add any you missed.

Now present the findings to the user and open the review file in their editor.

## Step 4: Apply the Recommendations

Ask the user if they would like to apply the recommendations. Keep in mind, when they say yes, they may have modified the review file, so you should re-read the skill and review the file again.