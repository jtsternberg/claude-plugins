# Skill Tools Plugin

Skills for creating, adapting, and reviewing agent skills, slash commands, and subagents, plus validating shared skills under Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install skill-tools@jtsternberg
```

## Description

Provides scaffolding, adaptation, and review tools for developing agent extensions. Helps preserve durable reasoning methods while maintaining consistency and quality across skills and commands.

The authoring, review, and validation skills are name-only (`disable-model-invocation: true`) and must be invoked explicitly. `adapt-skill` remains model-invocable because requests to adapt a supplied skill should route to it automatically.

## Skills

### `/skill-tools:create-skill`

End-to-end skill builder. Chains the official `skill-creator` → `review-skill` → auto-applies the review → opens the finished SKILL.md in your editor.

```
/skill-tools:create-skill <skill-name-or-description>
```

One up-front confirmation covers classification (project / personal / public) and save path; everything after runs straight through. Public skills get parameterized automatically using the same env-var pattern as `plugins/session-tools` (`$SESSIONS_RECAP_EXAMPLE`-style overrides with safe defaults).

Set `$CLAUDE_PUBLIC_SKILLS_DIR` to have the wrapper propose a default location for new public skills.

### `/skill-tools:adapt-skill`

Adapt a source skill's durable reasoning method to another job or workflow without baking one recipient domain into the general workflow.

```text
Claude Code plugin: /skill-tools:adapt-skill <source skill> for <recipient workflow>
Codex standalone: $adapt-skill <source skill> for <recipient workflow>
```

Supply a public GitHub URL, an exact local path, or an installed skill reference. The workflow separates invariants from domain details and presents an adaptation map for approval before drafting. It requires separate approval before writing a final draft to a user-named destination.

Source and recipient context may be sensitive. The skill does not harvest secrets, assumes no personal memory system, does not silently persist context, and has no dependency on a profile or interview plugin or special integration with one. A profile created elsewhere is merely an optional approved context attachment.

For standalone Codex installation:

```bash
bash scripts/install-standalone-skill.sh skill-tools:adapt-skill
```

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

### `/skill-tools:validate-dual-harness-skill`

Validate a new or edited skill against this repository's Claude Code and Codex contracts.

```text
Claude Code: /skill-tools:validate-dual-harness-skill <skill-name-or-path>
Codex: $skill-tools:validate-dual-harness-skill <skill-name-or-path>
```

Checks discovery, routing metadata, explicit-invocation gates, argument interpolation, runtime paths, dynamic context, permission assumptions, versioning, and focused behavioral proof.

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
- [skills/adapt-skill/SKILL.md](skills/adapt-skill/SKILL.md)
- [skills/create-slash-command/SKILL.md](skills/create-slash-command/SKILL.md)
- [skills/create-subagent/SKILL.md](skills/create-subagent/SKILL.md)
- [skills/review-skill/SKILL.md](skills/review-skill/SKILL.md)
- [skills/validate-dual-harness-skill/SKILL.md](skills/validate-dual-harness-skill/SKILL.md)
- [skills/review-slash-command/SKILL.md](skills/review-slash-command/SKILL.md)
