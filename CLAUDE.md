# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of Claude Code plugins (skills, commands, hooks) for sharing and reuse. Each plugin lives in its own directory under `plugins/`.

## Repository Structure

```
.claude-plugin/
├── plugin.json          # Plugin metadata
└── marketplace.json     # Marketplace registry of available plugins
plugins/
└── <plugin-name>/       # Each plugin in its own directory
    ├── manifest.json    # or .claude-plugin/plugin.json
    ├── hooks/           # Hook scripts (optional)
    └── commands/        # Slash command / skill markdown files (optional)
```

## Adding a New Plugin

1. Create a new directory under `plugins/<plugin-name>/`
2. Add required files (`manifest.json` or `.claude-plugin/plugin.json`, hooks, commands)
3. Register the plugin in `.claude-plugin/marketplace.json` by adding an entry to the `plugins` array
4. Update `README.md` with documentation for the new plugin

## Plugin Types

### Hook-based plugins
Hook scripts in `hooks/` that intercept Claude Code events (permissions, notifications, etc.) and return JSON decisions.

### Skill/Command-based plugins
Markdown files in `commands/` that define slash commands or skills Claude can invoke.

## Development Commands

```bash
# Install plugin locally for testing
claude plugins add /path/to/claude-plugins/plugins/<plugin-name>

# Test hook scripts directly (pipe JSON input)
echo '{"tool_name":"Bash","cwd":"/path","tool_input":{"command":"ls"}}' | bash plugins/<plugin-name>/hooks/<hook-script>.sh
```
