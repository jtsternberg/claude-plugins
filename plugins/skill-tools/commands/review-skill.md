---
description: "Review a skill for improvement opportunities against best practices"
argument-hint: "<skill-name-or-path>"
---

Review the skill at `$ARGUMENTS` for improvement opportunities.

Look for the skill at the provided path, or in `.claude/skills/$ARGUMENTS/` or `.claude/skills/monorepo-$ARGUMENTS/`.

## Step 1: Fetch Current Documentation

**REQUIRED**: Fetch these URLs for current best practices before reviewing:

* https://claude.com/blog/skills
* https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
* https://platform.claude.com/docs/en/agents-and-tools/agent-skills/quickstart
* https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

Extract key recommendations for: progressive disclosure, utility scripts, validation loops, metadata, content organization, and new patterns.

## Step 2: Read the Skill

Read SKILL.md and all bundled files at the skill path.

## Step 3: Evaluate & Report

Compare against fetched documentation. Focus solely on actionable improvements — no praise or congratulations.

1. **Summary**: Quick assessment (1-2 sentences)
2. **Issues**: Problems with specific line references
3. **Recommendations**: Prioritized improvements with code/text examples
4. **Script opportunities**: Bash/python scripts that could improve reliability

Output the review as a markdown file.
