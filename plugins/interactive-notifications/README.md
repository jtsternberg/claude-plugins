# Interactive Notifications

Respond to Claude Code permission requests and questions via native macOS dialogs — no need to switch to the terminal.

## Installation

```bash
/plugin install interactive-notifications@bvdr
```

> Requires the `bvdr` marketplace. Add it first if you haven't:
> ```bash
> /plugin marketplace add bvdr/claude-plugins
> ```

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

### Idle & Completion Alerts

- **Idle Alert** — Dialog when Claude has been waiting 60s+ for your input
- **Completion** — Notification when Claude finishes a task, with option to continue

### Context Information

Each dialog shows:
- **Folder path** — Last 3 directories (e.g., `../Sites/project/app`)
- **Tool details** — Command or file being accessed
- **Last request** — Your most recent message to Claude

## Timeout

Dialogs have a **5-minute timeout** (300 seconds). If you don't respond, it falls back to the terminal prompt.

## Requirements

- macOS (uses native `osascript` dialogs)
- `jq` for JSON parsing (`brew install jq`)

## License

MIT
