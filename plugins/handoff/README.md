# Handoff Plugin

Create handoff documents to preserve context between Claude Code sessions.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install handoff@jtsternberg
```

## Description

Generates comprehensive handoff documents that capture the current state of your work, making it easy to resume in a new Claude Code session without losing context.

## Command

### `/handoff`

Create a handoff document for the current session.

```
/handoff
```

**What It Captures:**
- Current task and progress
- Recent changes made
- Important context and decisions
- Next steps and recommendations
- File locations and key information

**Output:**
- Creates a markdown file with timestamp
- Saves to project root or specified location
- Ready to share with the next Claude Code session

## Example Usage

```bash
# At the end of a work session
/handoff
```

## Use Cases

- **Session Transitions**: End-of-day handoff to morning session
- **Collaboration**: Pass context to another developer
- **Long Tasks**: Preserve state for multi-day projects
- **Context Preservation**: Document complex reasoning and decisions

## How It Works

1. Analyzes git status and recent commits
2. Reviews conversation history for key decisions
3. Identifies open tasks and blockers
4. Generates structured markdown handoff document
5. Saves with timestamp for easy reference

## Additional Documentation

- [commands/handoff.md](commands/handoff.md) - Complete command documentation
