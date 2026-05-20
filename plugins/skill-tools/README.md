# Skill Tools Plugin

Skills for creating and reviewing Claude Code skills, slash commands, and subagents.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install skill-tools@jtsternberg
```

## Description

Provides scaffolding and review tools for developing Claude Code extensions. Helps maintain consistency and quality across skills and commands.

All skills in this plugin are name-only (`disable-model-invocation: true`) — invoke them explicitly by their namespaced path.

## Skills

### `/skill-tools:create-skill`

End-to-end skill builder. Chains the official `skill-creator` → `review-skill` → auto-applies the review → opens the finished SKILL.md in your editor.

```
/skill-tools:create-skill <skill-name-or-description>
```

One up-front confirmation covers classification (project / personal / public) and save path; everything after runs straight through. Public skills get parameterized automatically using the same env-var pattern as `plugins/session-tools` (`$SESSIONS_RECAP_EXAMPLE`-style overrides with safe defaults).

Set `$CLAUDE_PUBLIC_SKILLS_DIR` to have the wrapper propose a default location for new public skills.

### `/skill-tools:create-slash-command`

Create a new slash command with proper structure.

```
/skill-tools:create-slash-command <command-name> <description>
```

Guides you through creating a new slash command file with:
- Proper frontmatter structure
- Argument hints
- Tool allowlists
- Documentation templates

### `/skill-tools:create-subagent`

Create a new subagent configuration.

```
/skill-tools:create-subagent <subagent-name> <description-of-purpose>
```

Scaffolds a subagent definition with:
- Capability definitions
- Tool configurations
- Trigger patterns
- Best practices

### `/skill-tools:review-skill`

Review a skill for improvement opportunities.

```
/skill-tools:review-skill <path-to-skill.md>
```

Analyzes a skill file against best practices:
- Frontmatter validation
- Workflow clarity
- Documentation completeness
- Trigger pattern effectiveness
- Tool usage patterns

### `/skill-tools:review-slash-command`

Review a slash command for quality and consistency.

```
/skill-tools:review-slash-command <command-name>
```

Evaluates command files for:
- Frontmatter correctness
- Clear descriptions
- Proper tool allowlists
- User experience quality
- Documentation standards

## Example Usage

```bash
# Create a new slash command
/skill-tools:create-slash-command my-command "Does a thing"

# Review an existing skill
/skill-tools:review-skill plugins/my-skill/SKILL.md

# Review a slash command
/skill-tools:review-slash-command my-command
```

## Use Cases

- Creating new skills and commands
- Maintaining quality standards
- Onboarding to plugin development
- Code review for extensions
- Ensuring best practices

## Additional Documentation

- [skills/create-skill/SKILL.md](skills/create-skill/SKILL.md)
- [skills/create-slash-command/SKILL.md](skills/create-slash-command/SKILL.md)
- [skills/create-subagent/SKILL.md](skills/create-subagent/SKILL.md)
- [skills/review-skill/SKILL.md](skills/review-skill/SKILL.md)
- [skills/review-slash-command/SKILL.md](skills/review-slash-command/SKILL.md)
