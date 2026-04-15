# Review Skill

Review any Claude Code skill against current best practices from the official documentation.

## What it does

Runs a structured 4-step review of a skill's SKILL.md and supporting files:

1. **Read** the skill and all bundled files
2. **Evaluate** against the current Anthropic skills documentation, with emphasis on key areas like dynamic context, compaction, invocation control, and tool permissions
3. **Self-challenge** every recommendation — cuts anything that doesn't hold up
4. **Apply** approved fixes with your sign-off

Fetches and caches the latest skills documentation from code.claude.com so recommendations stay current.

## Usage

```
/review-skill <skill-name-or-path>
```

Examples:
```
/review-skill deploy
/review-skill ~/.claude/skills/my-skill/SKILL.md
/review-skill /path/to/skill-directory/SKILL.md
```

## What it checks

- Opportunities for dynamic context injection (`!`command``)
- Bash/sh scripts that could improve reliability
- `when_to_use` vs `description` separation
- Skill size, compaction resilience, and supporting file structure
- `disable-model-invocation` / `user-invocable` alignment
- `allowed-tools` scoping
- String substitution variable usage
- `context: fork` appropriateness

## Output

Writes a review to `/tmp/skill-review-{skill-name}.md` and opens it in your editor.

## Requirements

- `curl` (for fetching docs — cached for 24 hours)
