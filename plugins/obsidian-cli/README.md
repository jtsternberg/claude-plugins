# Obsidian CLI Plugin

Control Obsidian vaults from the terminal using the official Obsidian CLI (v1.12+).

## Installation

```bash
/plugin install obsidian-cli@jtsternberg
```

## Prerequisites

- **Obsidian 1.12 or later** with CLI support
- CLI enabled in **Settings > General > Command line interface**
- Obsidian app must be running (first command launches it if needed)
- PATH configured (macOS: `/Applications/Obsidian.app/Contents/MacOS` in PATH)

## Description

Interact with Obsidian vaults from Claude Code without reading full file contents into context. Manage notes, tasks, properties, daily notes, search, and more — all via command line.

## Usage

The skill triggers on mentions of:
- "obsidian"
- "vault"
- "daily note"
- "obsidian task"
- "obsidian search"
- Any Obsidian vault interaction request

## Common Workflows

### Daily Notes as Inbox

```bash
obsidian daily                                          # Open today's daily note
obsidian daily:read                                     # Read contents
obsidian daily:append content="- [ ] Buy groceries" silent  # Add task
obsidian daily:prepend content="## Morning Ideas" silent    # Prepend section
```

### Task Management

```bash
obsidian tasks                                # List all tasks
obsidian tasks done                          # List completed tasks
obsidian tasks:complete task="Buy groceries" # Mark task as done
```

### Search and Properties

```bash
obsidian search query="machine learning"     # Search vault
obsidian property:set file=Note prop=status value=draft  # Set property
obsidian property:get file=Note prop=status  # Get property value
```

## Additional Documentation

- [SKILL.md](SKILL.md) - Complete CLI reference and workflows
- [references/](references/) - Command examples and patterns
