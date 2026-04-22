# Research Tools

Tools for researching external sources from within Claude Code. Currently ships one skill:

- **[`fetch-docs`](skills/fetch-docs/SKILL.md)** — pull a URL's raw content into a local file so Claude reads the authoritative source instead of WebFetch's summary. Works on any http/https URL, with optional HTML→markdown conversion.

## Why

Claude Code's built-in `WebFetch` runs a small-model pass that summarizes and filters the page through the user's prompt. That pass routinely drops specifics — exact flag names, enum values, edge-case prose — the kind of detail you need when researching API shapes or CLI flags. `fetch-docs` bypasses that step: `curl` into `/tmp/`, return the path, `Read` it directly.

## Installation

Run these in a terminal (not inside a Claude Code session):

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install research-tools@jtsternberg
```

## Prerequisites

- **`curl`** — required for every call. Ships with macOS and almost every Linux distro.
- **`node` / `npx`** — only needed when you pass `--md` on an HTML source. Markdown-native URLs skip the conversion pipeline entirely. Both `readability-cli` and `turndown-cli` run through `npx -y` on first use, so there's nothing to `npm install`.

```bash
# macOS
brew install node      # if npx isn't already on PATH

# Linux
# Use your distro's package manager or https://nodejs.org
```

## Usage

Once installed, invoke the skill with `/fetch-docs <url>` or let Claude trigger it when you ask for the raw page. Behind the scenes it runs the bundled `scripts/fetch-docs.sh`:

```bash
# Raw HTML (default)
bash plugins/research-tools/skills/fetch-docs/scripts/fetch-docs.sh "https://example.com/docs"

# HTML source → markdown
bash plugins/research-tools/skills/fetch-docs/scripts/fetch-docs.sh "https://example.com/docs" --md

# Markdown-native URL (auto-detected, no conversion run)
bash plugins/research-tools/skills/fetch-docs/scripts/fetch-docs.sh "https://code.claude.com/docs/en/skills.md"

# Custom slug + short TTL
bash plugins/research-tools/skills/fetch-docs/scripts/fetch-docs.sh "https://example.com/api" --slug=my-api --ttl=3600
```

The script prints the cached file path on stdout. See the [SKILL.md](skills/fetch-docs/SKILL.md) for the full workflow, cache semantics, and troubleshooting.

## Structure

```
plugins/research-tools/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    └── fetch-docs/
        ├── SKILL.md
        └── scripts/
            └── fetch-docs.sh
```

## Roadmap

Other research-infrastructure skills that may live in this plugin over time:

- Multi-URL batch fetch
- Sitemap discovery and cached-docs library browser
- RSS/Atom readers
- Domain-scoped search helpers
- An auto-suggest hook that proposes `fetch-docs` when WebFetch is used on a docs URL
