# Claude Code Plugins by JTSternberg

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-blueviolet)](https://claude.com/claude-code)

A curated collection of Claude Code plugins — skills, commands, hooks, and automation.

---

## Quick Start

Add the marketplace and install any plugin:

```bash
/plugin marketplace add jtsternberg/claude-plugins
/plugin install git-tree@jtsternberg  # Example: install git-tree skill
```

Verify installation:

```bash
/plugin list
```

---

## Plugins

### Skills

#### 🌳 [git-tree](plugins/git-tree)
Create git worktrees with symlinked dependencies. Perfect for parallel branch work.

**Install:** `/plugin install git-tree@jtsternberg`

#### 📰 [headline-refiner](plugins/headline-refiner)
Refines headlines using the 5-Part Headline Framework (Number, What, Who, Why, Twist the Knife).

**Install:** `/plugin install headline-refiner@jtsternberg`

#### 📝 [obsidian-cli](plugins/obsidian-cli)
Interacts with Obsidian vaults from the terminal using the official Obsidian CLI (v1.12+).

**Install:** `/plugin install obsidian-cli@jtsternberg`

#### 📊 [publish-insights](plugins/publish-insights)
Publish Claude Code `/insights` reports to GitHub Pages for easy sharing.

**Install:** `/plugin install publish-insights@jtsternberg`

#### 🖼️ [generating-blog-images](plugins/generating-blog-images)
Generate AI image prompts for blog posts by analyzing content and identifying optimal placement.

**Install:** `/plugin install generating-blog-images@jtsternberg`

### Commands

#### 💬 [git-commits](plugins/git-commits)
Commands for creating git commits from staged or unstaged files with AI-generated messages.

**Commands:** `/commit-staged`, `/commit-unstaged`

**Install:** `/plugin install git-commits@jtsternberg`

#### 🔀 [pr-workflow](plugins/pr-workflow)
Commands for managing pull requests: addressing comments and updating descriptions.

**Commands:** `/address-pr-comments`, `/update-pr-description`

**Install:** `/plugin install pr-workflow@jtsternberg`

#### 🛠️ [skill-tools](plugins/skill-tools)
Commands for creating and reviewing Claude Code skills, slash commands, and subagents.

**Commands:** `/create-slash-command`, `/create-subagent`, `/review-skill`, `/review-slash-command`

**Install:** `/plugin install skill-tools@jtsternberg`

#### 📦 [beads-workflow](plugins/beads-workflow)
Work through beads epics from start to completion with automatic PR creation.

**Commands:** `/tackle-epic`

**Dependencies:** Requires [beads](https://github.com/steveyegge/beads)

**Install:** `/plugin install beads-workflow@jtsternberg`

#### 🤝 [handoff](plugins/handoff)
Create handoff documents to preserve context between Claude Code sessions.

**Commands:** `/handoff`

**Install:** `/plugin install handoff@jtsternberg`

### Status Lines

#### 📊 [workspace-status](plugins/workspace-status)
Status line showing model name, current directory, git branch/status, and context usage bar.

**Note:** Requires manual setup (status lines use a different configuration mechanism).

**Setup:** Update `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "php /path/to/claude-plugins/plugins/workspace-status/workspace-status.php",
    "padding": 0
  }
}
```

---

## 🔧 Development

### Clone the Repository

```bash
git clone https://github.com/jtsternberg/claude-plugins.git
cd claude-plugins
```

### Install the Marketplace Locally

Add the local directory as a marketplace in your `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "jtsternberg": {
      "source": {
        "source": "local",
        "path": "/path/to/claude-plugins"
      }
    }
  }
}
```

### Install a Plugin Directly from Local Files

```bash
claude plugins add /path/to/claude-plugins/plugins/<plugin-name>
```

### Repository Structure

```
.claude-plugin/
├── plugin.json          # Plugin metadata
└── marketplace.json     # Marketplace registry
plugins/
└── <plugin-name>/       # Each plugin in its own directory
    ├── manifest.json    # Plugin manifest
    ├── hooks/           # Hook scripts (optional)
    └── commands/        # Slash commands / skills (optional)
```

---

## Contributing

Contributions are welcome! To add a new plugin:

1. Fork this repository
2. Create a new directory under `plugins/`
3. Add required files (`manifest.json` or `.claude-plugin/plugin.json`, hooks, commands)
4. Register it in `.claude-plugin/marketplace.json`
5. Update this README with documentation
6. Submit a pull request

---

## License

MIT License — see [LICENSE](LICENSE) for details.
