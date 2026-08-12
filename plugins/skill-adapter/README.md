# Skill Adapter Plugin

Adapt a reusable skill's durable reasoning method to another job or workflow without baking one recipient domain into the general workflow.

## Installation

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install skill-adapter@jtsternberg
```

The repository currently publishes this plugin through the Claude Code marketplace. The skill itself follows the shared Claude/Codex authoring contract and can be installed as a [standalone Codex skill](../../docs/codex/standalone-skills.md).

```bash
bash scripts/install-standalone-skill.sh skill-adapter:adapt-skill
```

## Skill

### `adapt-skill`

Supply a public GitHub URL, an exact local path, or an installed skill reference and name the recipient workflow:

```text
Claude Code plugin: /skill-adapter:adapt-skill <source skill> for <recipient workflow>
Codex standalone: $adapt-skill <source skill> for <recipient workflow>
```

The workflow extracts source invariants, separates domain details, and presents an adaptation map for approval before drafting. It drafts a compatible Claude Code skill by default; for another agent environment it uses a verified native format when available or a portable instruction bundle when direct compatibility cannot be verified.

Source and recipient context may be sensitive. The skill does not harvest secrets, assumes no personal memory system, does not silently persist context, and requires separate approval before writing an approved draft to a user-named destination.

`adapt-skill` has no dependency on a profile or interview plugin. A profile created elsewhere can be passed in as an optional approved context attachment, but receives no special integration and is never discovered automatically.
