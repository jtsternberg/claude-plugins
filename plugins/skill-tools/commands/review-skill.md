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

and recent tweet (https://x.com/lydiahallie/status/2034337963820327017?s=20) says:
```
if your skill depends on dynamic content, you can embed !`command` in your SKILL.md to inject shell output directly into the prompt

Claude Code runs it when the skill is invoked and swaps the placeholder inline, the model only sees the result!
```

Extract key recommendations for: progressive disclosure, utility scripts, validation loops, metadata, content organization, and new patterns.

## Step 2: Read the Skill

Read SKILL.md and all bundled files at the skill path.

## Step 3: Evaluate & Report

Compare against fetched documentation. Focus solely on actionable improvements — no praise or congratulations.

1. **Summary**: Quick assessment (1-2 sentences)
2. **Issues**: Problems with specific line references
3. **Recommendations**: Prioritized improvements with code/text examples
4. **Script opportunities**: Bash/python scripts that could improve reliability
5. **Inline shell execution**: Does this skill hardcode context that could be dynamic? Check for opportunities to use `!`command`` syntax (single-line) or ` ```! ` fenced blocks (multi-line) to inject runtime context — current date, git branch, environment info, project metadata, etc. These run at skill load time and inline the output before Claude sees the prompt. Flag any static values that would be more accurate or useful if computed on the fly.

Output the review as a markdown file.
