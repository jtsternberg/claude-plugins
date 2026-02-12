# Workspace Status Plugin

Status line showing model name, current directory, git branch/status, and context usage bar.

## Installation

**Note:** This plugin requires manual configuration as status lines use a different mechanism than other plugins.

## Setup

Add the following to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "php /path/to/claude-plugins/plugins/workspace-status/workspace-status.php",
    "padding": 0
  }
}
```

Replace `/path/to/claude-plugins/` with the actual path to your clone of this repository.

## Description

Displays a dynamic status line at the bottom of your Claude Code terminal showing:

- **Model name**: Current Claude model in use
- **Current directory**: Working directory name
- **Git branch**: Active git branch (if in a repo)
- **Git status**: Clean, modified, or staged indicator
- **Context usage**: Visual bar showing conversation context consumption

## Example Output

```
claude-sonnet-4 | ~/my-project | main ✓ | ████████░░ 80%
```

## Requirements

- **PHP**: Must be installed and in PATH
- **Git**: For git status features (optional)

## Customization

Edit `workspace-status.php` to customize:
- Status line format
- Colors and symbols
- Displayed information
- Update frequency

## Troubleshooting

**Status line not showing:**
- Verify PHP is installed: `php --version`
- Check file path in settings.json is correct
- Ensure file is executable: `chmod +x workspace-status.php`

**Git status not working:**
- Verify you're in a git repository
- Check git is installed: `git --version`

## Additional Documentation

- [workspace-status.php](workspace-status.php) - Source code and inline documentation
