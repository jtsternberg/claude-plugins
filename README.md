# Claude Code Plugins by JT Sternberg

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-blueviolet)](https://claude.com/claude-code)

A curated collection of Claude Code plugins — skills, commands, hooks, and automation.

---

## Quick Start

Add the marketplace and install any plugin:

```bash
/plugin marketplace add jtsternberg/claude-plugins
/plugin install <plugin-name>@jtsternberg
```

---

## Plugins

_No plugins yet — add your first one under `plugins/`!_

---

## Development

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
