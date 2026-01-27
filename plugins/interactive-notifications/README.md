# Interactive Notifications Plugin for Claude Code

Respond to Claude Code permission requests and questions via native macOS dialogs — no need to switch to the terminal.

## Features

### Permission Dialogs
When Claude asks for permission to run a command, edit a file, etc., you'll see a macOS dialog with:
- **Yes** — Approve the action
- **No** — Deny the action
- **Reply** — Type a custom message to Claude

### Question Dialogs
When Claude asks you a question with multiple options (via `AskUserQuestion`), you'll see:
- **Buttons** for 2-3 options
- **Selectable list** for 4+ options
- **"Other"** option for custom text input
- **Multi-select** support for questions that allow multiple answers

### Context Information
Each dialog shows:
- **Folder path**: Last 3 directories (e.g., `../Sites/project/app`)
- **Tool details**: Command or file being accessed
- **Last request**: Your most recent message to Claude

## Installation

### From local path
```bash
claude plugins add ~/gits/bvdr/claude-plugins/plugins/interactive-notifications
```

### From GitHub (after publishing)
```bash
claude plugins add github:bvdr/claude-plugins --path plugins/interactive-notifications
```

## Configuration

The plugin automatically configures these hooks:

| Hook | Matcher | Purpose |
|------|---------|---------|
| `PermissionRequest` | `*` | All permission dialogs |
| `PreToolUse` | `AskUserQuestion` | Claude's questions to user |

### Timeout
Dialogs have a **5-minute timeout** (300 seconds). If you don't respond, it falls back to the terminal prompt.

## Requirements

- macOS (uses native `osascript` dialogs)
- `jq` for JSON parsing (install via `brew install jq`)

## Log Files

For debugging, logs are written to:
- `~/.claude/hooks/permission.log` — Permission dialog activity
- `~/.claude/hooks/questions.log` — Question dialog activity

## How It Works

1. Claude Code triggers a permission request or question
2. The hook intercepts and parses the request
3. A native macOS dialog appears with relevant options
4. Your selection is returned to Claude Code
5. Claude continues based on your choice

## License

MIT
