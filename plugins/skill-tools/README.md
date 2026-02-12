# Skill Tools Plugin

Commands for creating and reviewing Claude Code skills, slash commands, and subagents.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install skill-tools@jtsternberg
```

## Description

Provides scaffolding and review tools for developing Claude Code extensions. Helps maintain consistency and quality across skills and commands.

## Commands

### `/create-slash-command`

Create a new slash command with proper structure.

```
/create-slash-command
```

Guides you through creating a new slash command file with:
- Proper frontmatter structure
- Argument hints
- Tool allowlists
- Documentation templates

### `/create-subagent`

Create a new subagent configuration.

```
/create-subagent
```

Scaffolds a subagent definition with:
- Capability definitions
- Tool configurations
- Trigger patterns
- Best practices

### `/review-skill`

Review a skill for improvement opportunities.

```
/review-skill <path-to-skill.md>
```

Analyzes a skill file against best practices:
- Frontmatter validation
- Workflow clarity
- Documentation completeness
- Trigger pattern effectiveness
- Tool usage patterns

### `/review-slash-command`

Review a slash command for quality and consistency.

```
/review-slash-command <path-to-command.md>
```

Evaluates command files for:
- Frontmatter correctness
- Clear descriptions
- Proper tool allowlists
- User experience quality
- Documentation standards

## Example Usage

```bash
# Create a new command
/create-slash-command

# Review an existing skill
/review-skill plugins/my-skill/SKILL.md

# Review a command
/review-slash-command plugins/my-plugin/commands/my-command.md
```

## Use Cases

- Creating new skills and commands
- Maintaining quality standards
- Onboarding to plugin development
- Code review for extensions
- Ensuring best practices

## Additional Documentation

- [commands/create-slash-command.md](commands/create-slash-command.md)
- [commands/create-subagent.md](commands/create-subagent.md)
- [commands/review-skill.md](commands/review-skill.md)
- [commands/review-slash-command.md](commands/review-slash-command.md)
