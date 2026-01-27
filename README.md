# Claude Plugins by bvdr

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-blueviolet)](https://claude.com/claude-code)

A curated collection of custom Claude Code plugins and skills for macOS productivity, development workflows, and automation.

## Table of Contents

- [Installation](#installation)
- [Plugins](#plugins)
- [Skills](#skills)
- [Usage](#usage)
- [Contributing](#contributing)
- [Resources](#resources)
- [License](#license)

---

## Installation

### Option 1: Add as Plugin Marketplace (Recommended)

Add this repository as a plugin marketplace in Claude Code:

```bash
/plugin marketplace add bvdr/claude-plugins
```

Then install individual plugins:

```bash
/plugin install interactive-notifications@bvdr
/plugin install macos-use-voice-alerts@bvdr
```

### Option 2: Clone and Use Locally

```bash
# Clone the repository
git clone https://github.com/bvdr/claude-plugins.git

# Start Claude Code with the plugin directory
claude --plugin-dir ./claude-plugins
```

### Option 3: Add to Settings (Auto-Install)

Add to your `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "bvdr": {
      "source": {
        "source": "github",
        "repo": "bvdr/claude-plugins"
      }
    }
  },
  "enabledPlugins": {
    "interactive-notifications@bvdr": true,
    "macos-use-voice-alerts@bvdr": true
  }
}
```

---

## Plugins

| Plugin | Description | Platform |
|--------|-------------|----------|
| [interactive-notifications](#interactive-notifications) | macOS dialogs for permissions, questions, idle alerts, and completion | macOS |

---

### interactive-notifications

Respond to Claude Code from anywhere on your Mac via native macOS dialogs — no need to switch to the terminal.

**Install:**
```bash
/plugin install interactive-notifications@bvdr
```

**Features:**

| Hook | Trigger | Buttons |
|------|---------|---------|
| Permission Requests | Claude asks for permission | Reply / No / Yes |
| Questions | Claude asks you a question | Clickable options |
| Idle Alert | Claude waiting 60s+ | Reply / OK |
| Completion | Claude finishes task | Continue / OK |

**Dialog shows:**
- Folder path (last 3 directories)
- Tool/command details
- Your last request for context

**Buttons:**
- **Yes** — Approve action
- **No** — Deny action
- **Reply** — Type a custom message
- **Continue** — Type follow-up to keep Claude working
- **OK** — Acknowledge and dismiss

**Requirements:**
- macOS (uses native `osascript` dialogs)
- `jq` for JSON parsing (`brew install jq`)

**Timeout:** 5 minutes (falls back to terminal if no response)

---

## Skills

| Skill | Description | Platform |
|-------|-------------|----------|
| [macos-use-voice-alerts](#macos-use-voice-alerts) | Enable verbal notifications using macOS text-to-speech | macOS |
| [setup-statusline](#setup-statusline) | Interactive wizard to configure a custom statusline | macOS, Linux |

---

### macos-use-voice-alerts

Enable verbal notifications using macOS text-to-speech to alert when Claude needs human intervention or completes a task.

**Invoke:**
```
/macos-use-voice-alerts
```

**With custom voice:**
```
/macos-use-voice-alerts Zarvox
```

**Features:**
- Announces questions before asking
- Alerts when permissions are needed
- Notifies on task completion
- Warns about errors and blockers
- Persists for entire session until `/clear`

**Popular Voice Options:**

| Voice | Style | Use Case |
|-------|-------|----------|
| `Zarvox` | Robotic | Fun, classic sci-fi feel |
| `Whisper` | Quiet | Discrete, subtle notifications |
| `Good News` | Upbeat | Positive task completions |
| `Bad News` | Ominous | Error notifications |
| `Jester` | Comedic | Playful interactions |
| `Samantha` | Natural | Professional settings |

---

### setup-statusline

Interactive wizard to configure a custom Claude Code statusline with folder display, git info, context bar, and last message.

**Invoke:**
```
/setup-statusline
```

**Configuration options:**
- **Folder**: Last folder only / Last 2 folders / Full path / Hidden
- **Color**: Blue / Orange / Green / Gray
- **Git**: Full status / Branch only / No git info
- **Last message**: Show your last prompt on second line

**Example output:**
```
📁myproject | 🔀main (2 files uncommitted, synced) | [███░░░░░░░] 15% of 200k tokens used
💬 Can you check if the edd license plugin is enabled...
```

**Features:**
- Visual context bar showing token usage
- Git branch with uncommitted count and sync status
- Second line shows your last message for easy conversation identification
- Color-coded with customizable accent colors
- Automatically updates `settings.json`

**Requirements:**
- `jq` for JSON parsing
- `git` for branch info (optional)

---

## Usage

### Installing Plugins

```bash
/plugin install <plugin-name>@bvdr
```

### Invoking Skills

```
/<skill-name> [arguments]
```

### Checking Available Plugins/Skills

```
/plugin list
/skill list
```

### Discovering Voices (macOS)

To see all available text-to-speech voices on your system:

```bash
say -v "?"
```

---

## Contributing

Contributions are welcome! To add a new plugin or skill:

1. Fork this repository
2. Create a new directory under `plugins/` or `skills/`
3. Add required files (manifest.json, hooks, etc.)
4. Update the `marketplace.json` with your entry
5. Update this README with documentation
6. Submit a pull request

---

## Resources

- [Claude Code Documentation](https://code.claude.com/docs)
- [Creating Skills Guide](https://code.claude.com/docs/en/skills)
- [Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Plugin Marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

Made with Claude Code
