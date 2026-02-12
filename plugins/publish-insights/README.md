# Publish Insights Plugin

Publish Claude Code `/insights` reports to GitHub Pages for easy sharing.

> **Note:** This plugin is maintained in the [claude-usage-data](https://github.com/jtsternberg/claude-usage-data) repository.

## Installation

```bash
# Add the marketplace
/plugin marketplace add jtsternberg/claude-usage-data

# Install the plugin
/plugin install publish-insights@jtsternberg/claude-usage-data
```

## Prerequisites

- **GitHub CLI (`gh`)**: Must be installed and authenticated
  - Install: `brew install gh` (macOS) or see [GitHub CLI docs](https://cli.github.com/)
  - Authenticate: `gh auth login`
- **Git**: Must be installed

## Description

Automates the entire process of publishing your Claude Code insights report to GitHub Pages, making it easy to share usage statistics and analytics.

## Usage

The skill triggers when you:
- "publish insights"
- "share my insights report"
- "put insights on GitHub Pages"
- Ask about publishing after generating an `/insights` report

## How It Works

1. Locates your insights report at `~/.claude/usage-data/report.html`
2. Detects your GitHub username
3. Confirms repository settings (name, visibility)
4. Creates GitHub repository
5. Enables GitHub Pages
6. Pushes report and README
7. Monitors deployment
8. Provides live URL

## Example Session

```
User: "Publish my insights report"

Claude:
  ✓ Found report at ~/.claude/usage-data/report.html
  ✓ Detected GitHub user: jtsternberg
  ✓ Creating public repo: claude-insights
  ✓ Enabled GitHub Pages
  ✓ Deployed to: https://jtsternberg.github.io/claude-insights/

Your insights are now publicly accessible!
```

## Configuration Options

During setup, you'll be prompted for:
- **Repository name** (default: `claude-insights`)
- **Visibility** (public or private)
- **GitHub Pages settings** (branch, path)

## Verification

The skill automatically verifies:
- Prerequisites (gh, git)
- File locations
- GitHub authentication
- Deployment status
- Live URL accessibility

## Additional Documentation

- [SKILL.md](SKILL.md) - Complete workflow and troubleshooting
