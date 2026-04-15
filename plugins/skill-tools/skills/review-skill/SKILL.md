---
name: review-skill
description: "Review a skill for improvement opportunities against best practices"
argument-hint: "<skill-name-or-path>"
disable-model-invocation: true
---

Your job will be to review the skill at `$ARGUMENTS` for improvement opportunities.

Look for the skill at the provided path, or in `.claude/skills/$ARGUMENTS/` or `.claude/skills/monorepo-$ARGUMENTS/`.

## Current Skills Documentation

```!
curl -sL https://code.claude.com/docs/en/skills.md
```

If the above is empty or shows an error, tell the user the docs URL is unreachable and stop.

## Step 1: Read the Skill

Read SKILL.md and all bundled files/scripts/etc at the skill path.

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

## Step 3: Challenge Your Review

ultrathink

Re-read your review against the docs and the skill. For each recommendation, ask:

- **Does this actually apply to this skill?** Don't recommend patterns that solve problems the skill doesn't have.
- **Is this solving a real problem or a hypothetical one?** If you can't point to a concrete failure mode, cut it.
- **Did you miss anything?** Re-scan the docs for patterns the skill could benefit from that you didn't catch in Step 2.

Update the review file — remove recommendations that don't hold up, add any you missed.

Now present the findings to the user, and use $EDITOR to open the review file for them to review/collaborate on.

## Step 4: Apply the Recommendations

Ask the user if they would like to apply the recommendations. Keep in mind, when they say yes, they may have modified the review file, so you should re-read the skill and review the file again.