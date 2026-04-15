---
name: review-skill
description: "Review a skill for improvement opportunities against best practices"
argument-hint: "<skill-name-or-path>"
disable-model-invocation: true
---

Review the skill at `$ARGUMENTS` for improvement opportunities.

Look for the skill at the provided path, or in `.claude/skills/$ARGUMENTS/` or `.claude/skills/monorepo-$ARGUMENTS/`.

## Step 1: Fetch Docs & Read the Skill (in parallel)

Do both of these at the same time:

1. **Fetch current documentation** **using `curl`**, fetch https://code.claude.com/docs/en/skills.md contents.
   - Do NOT use webfetch tool, as it will be summarized.
   - If the request fails, tell the user the docs URL is unreachable and stop.
2. **Read the skill**: Read SKILL.md and all bundled files/scripts/etc at the skill path.

Key areas to emphasize:
1. **Inject dynamic context**: Does this skill hardcode context that could be dynamic? Check for opportunities to use `!`command`` syntax (single-line) or ` ```! ` fenced blocks (multi-line) to inject runtime context — current date, git branch, environment info, project metadata, etc. These run at skill load time and inline the output before Claude sees the prompt. Flag any static values that would be more accurate or useful if computed on the fly. This is a great way to reduce the size of the skill and make it more maintainable.
2. **Script opportunities**: Bash/sh scripts that could improve reliability and save on tokens.


## Step 2: Evaluate & Report

Compare against fetched documentation. Focus solely on actionable improvements — no praise or congratulations.

Extract key recommendations for: progressive disclosure, utility scripts, validation loops, metadata, frontmatter validation, content organization, inline script execution, and new patterns.

1. **Summary**: Quick assessment (1-2 sentences)
2. **Issues**: Problems with specific line references
3. **Recommendations**: Prioritized improvements with code/text examples

Output the review as a markdown file.

Ask the user if they would like to apply the recommendations.