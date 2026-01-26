# Claude Code Skills by bvdr

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-blueviolet)](https://claude.com/claude-code)

A curated collection of custom Claude Code skills for macOS productivity, development workflows, and automation.

## Table of Contents

- [Installation](#installation)
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
/plugin marketplace add bvdr/claude-code-skills
```

Then install individual skills:

```bash
/plugin install macos-use-voice-alerts@bvdr-skills
```

### Option 2: Clone and Use Locally

```bash
# Clone the repository
git clone https://github.com/bvdr/claude-code-skills.git

# Start Claude Code with the plugin directory
claude --plugin-dir ./claude-code-skills
```

### Option 3: Add to Settings (Auto-Install)

Add to your `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "bvdr-skills": {
      "source": {
        "source": "github",
        "repo": "bvdr/claude-code-skills"
      }
    }
  },
  "enabledPlugins": {
    "macos-use-voice-alerts@bvdr-skills": true
  }
}
```

---

## Skills

| Skill | Description | Platform |
|-------|-------------|----------|
| [macos-use-voice-alerts](#macos-use-voice-alerts) | Enable verbal notifications using macOS text-to-speech | macOS |

---

### macos-use-voice-alerts

Enable verbal notifications using macOS text-to-speech to alert when Claude needs human intervention or completes a task.

**Invoke:**
```
/bvdr-skills:macos-use-voice-alerts
```

**With custom voice:**
```
/bvdr-skills:macos-use-voice-alerts Zarvox
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

**Example with voice:**
```
/bvdr-skills:macos-use-voice-alerts Whisper
```

---

## Usage

### Invoking Skills

Skills from this marketplace are namespaced under `bvdr-skills`. Use the format:

```
/bvdr-skills:<skill-name> [arguments]
```

### Checking Available Skills

List all installed skills:

```
/skill list
```

### Discovering Voices (macOS)

To see all available text-to-speech voices on your system:

```bash
say -v "?"
```

---

## Contributing

Contributions are welcome! To add a new skill:

1. Fork this repository
2. Create a new directory under `skills/` with your skill name
3. Add a `SKILL.md` file following the [Claude Code skill format](https://code.claude.com/docs/en/skills)
4. Update the `marketplace.json` with your skill entry
5. Update this README with your skill documentation
6. Submit a pull request

### Skill Template

```markdown
---
name: your-skill-name
description: Brief description of what your skill does
---

# Your Skill Name

Full instructions for Claude to follow when this skill is invoked.
```

---

## Resources

- [Claude Code Documentation](https://code.claude.com/docs)
- [Creating Skills Guide](https://code.claude.com/docs/en/skills)
- [Plugin Marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
- [awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) - Community curated list

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

Made with Claude Code
