# Claude Code and Codex Plugins by JTSternberg

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-blueviolet)](https://claude.com/claude-code)
[![Codex](https://img.shields.io/badge/Codex-compatible-111827)](https://developers.openai.com/codex/)

A curated collection of skills, hooks, and automation for Claude Code and
Codex. The two harnesses use different catalogs in this repository, so check
the [support matrix](docs/codex/compatibility.md#plugin-support-matrix) before
installing.

---

## Quick Start

### Claude Code

Add the marketplace and install any of its 27 listed plugins:

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install git-tree@jtsternberg
```

Verify installation:

```bash
claude plugin list
```

Invoke an installed skill as `/<plugin>:<skill-name>`, using the skill's
frontmatter `name`. For example: `/pr-workflow:qa-walkthrough-pr`.

### Codex

Codex's native catalog currently offers `codex`, `pr-workflow`, and `hotline`:

```bash
codex plugin marketplace add jtsternberg/claude-plugins
codex plugin add codex@jtsternberg
```

Open `/plugins` in Codex to browse configured marketplaces, or run
`codex plugin list --available --json` in a terminal. Start a new session after
installation, then mention a skill as `$<plugin>:<skill-name>`; for example,
`$codex:fable-mode`.

To install one self-contained repository skill instead of a whole plugin, see
[standalone Codex skills](docs/codex/standalone-skills.md). For commands,
updates, catalog scope, and all 28 plugin names, see the
[Codex compatibility guide](docs/codex/compatibility.md).

---

## Plugins

### Skills

#### 🌳 [git-tree](plugins/git-tree)
Create git worktrees with symlinked dependencies. Perfect for parallel branch work.

**Install:** `claude plugin install git-tree@jtsternberg`

#### 📰 [headline-refiner](plugins/headline-refiner)
Refines headlines using the 5-Part Headline Framework (Number, What, Who, Why, Twist the Knife).

**Install:** `claude plugin install headline-refiner@jtsternberg`

#### 📝 [obsidian-cli](plugins/obsidian-cli)
Interacts with Obsidian vaults from the terminal using the official Obsidian CLI (v1.12+).

**Install:** `claude plugin install obsidian-cli@jtsternberg`

#### 📊 [publish-insights](https://github.com/jtsternberg/claude-usage-data)
Publish Claude Code `/insights` reports to GitHub Pages for easy sharing.

**Install:** 
```bash
claude plugin marketplace add jtsternberg/claude-usage-data
claude plugin install publish-insights@jtsternberg/claude-usage-data
```

#### 🖼️ [generating-blog-images](plugins/generating-blog-images)
Generate AI image prompts for blog posts by analyzing content and identifying optimal placement.

**Install:** `claude plugin install generating-blog-images@jtsternberg`

#### 🐘 [localwp-shell](plugins/localwp-shell)
Wraps WP-CLI, PHP, MySQL, and Composer commands through LocalWP's sandboxed environment. Auto-detects the correct site from the current directory.

**Install:** `claude plugin install localwp-shell@jtsternberg`

#### 🎬 [slides-presentation](plugins/slides-presentation)
Creates self-contained HTML slide presentations from talk prompts, outlines, or content descriptions. Supports dark/light themes, SVG diagrams, and AI-generated illustrations.

**Install:** `claude plugin install slides-presentation@jtsternberg`

#### 📤 [export-presentation](plugins/export-presentation)
Exports HTML slide presentations to PDF or PNG screenshots using browser automation. Companion to [slides-presentation](#-slides-presentation).

**Install:** `claude plugin install export-presentation@jtsternberg`

#### 📞 [hotline](plugins/hotline)
Cross-workspace communication for agent sessions. Claude Code and Codex can place calls; the current launch transport starts Claude Code receivers. Also ships a [standalone session ID discovery utility](plugins/hotline/SESSION-ID-DISCOVERY.md).

**Install:** `claude plugin install hotline@jtsternberg` or `codex plugin add hotline@jtsternberg`

#### 🧠 [thinking-tools](plugins/thinking-tools)
Metacognitive reasoning frameworks for careful decision-making. Ships `chestertons-fence` (investigate before removing), `pink-elephant` (rewrite counterproductive prohibitions as positive directives), and `interview-mode` (after two rejected drafts of the same artifact, stop generating variants and interview the user to build from their own wording).

**Install:** `claude plugin install thinking-tools@jtsternberg`

#### 📅 [session-tools](plugins/session-tools)
Tools for managing Claude Code session transcripts — recaps, cleanup, retitling, etc. Ships `sessions-weekly-recap` (daily/weekly recap notes + macOS launchd installer) and `sessions-catch-up` (brief yourself on another session — including a `claude export`-style transcript reader that works on dead sessions).

**Install:** `claude plugin install session-tools@jtsternberg`

#### 🎙️ [work-with-media](plugins/work-with-media)
Turn audio and video into text on macOS. Bundles a [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper) CLI wrapper (local file transcription) and a yt-dlp skill (YouTube/Vimeo/URL — captions, description, chapters, or audio download as a transcription fallback). Subs-first for URLs, so a TLDR doesn't require downloading 20 MB of audio.

**Install:** `claude plugin install work-with-media@jtsternberg`

#### 📚 [research-tools](plugins/research-tools)
Research infrastructure for Claude Code. Ships `fetch-docs` — pulls a URL's raw content into a local file so Claude reads the authoritative source instead of WebFetch's filtered summary. Works on any http/https URL; optional HTML→markdown conversion via `npx`.

**Install:** `claude plugin install research-tools@jtsternberg`

#### 🪟 [cmux-cli](plugins/cmux-cli)
Control [cmux](https://cmux.sh) (macOS terminal multiplexer / workspace manager) from the command line. Bundled workflows cover the two common agent tasks — opening a side-by-side surface in the current window, and finding / reading / driving another tab by name or on-screen content. Also exposes notifications, sidebar progress pills, tmux-compat commands, SSH remote workspaces, and the embedded browser. Includes an `auto-rename` skill that summarizes what a tab or workspace is doing (including claude/codex agent sessions) and gives it a concise, meaningful name.

**Install:** `claude plugin install cmux-cli@jtsternberg`

#### 📖 [fable](plugins/fable)
Skills for working with — and like — the Fable model (`claude-fable-5`). Ships `fable-delegate`: delegation discipline that keeps a Fable main agent in the thinker/boss role — planning, judgment, and reviewing output — while routing file edits, searches, tests, and other mechanical execution to Opus/Sonnet subagents. And `fable-mode`: the operating stance behind Fable's judgment — own the outcome, not the response — for agents running on Opus-level models — with the habits that stance generates (fix the class not the instance, follow your own diagnosis, spend the user's attention like a budget, verify end-to-end) — plus a Sonnet variant that keeps the stance's values but re-fences autonomy behind bright-line guardrails.

**Install:** `claude plugin install fable@jtsternberg`

#### 🧪 [codex](plugins/codex)
Codex-native A/B experiments: `codex:sol-delegate` for Sol-led delegation to Terra and other available models, plus `codex:fable-mode` and `codex:sol-mode` for comparing competitive frontier-model stances on Terra.

**Install:** `codex plugin add codex@jtsternberg`

### Workflow skills

#### 💬 [git-commits](plugins/git-commits)
Skills for creating git commits from staged or unstaged files with AI-generated messages. The skills are dual-harness compatible, but this repository currently offers the plugin only through its Claude Code catalog.

**Skills:** `commit-staged`, `commit-unstaged`

**Install:** `claude plugin install git-commits@jtsternberg`

#### 🔀 [pr-workflow](plugins/pr-workflow)
Skills for managing pull requests: addressing comments, updating descriptions, watching PRs, and guiding QA.

**Skills:** `address-pr-comments`, `address-pr-comments-human`, `update-pr-description`, `watch-pr-then-action`, `qa-walkthrough-pr`

Available in both the Claude Code and Codex-native catalogs.

**Supports:** [`CODE_CONVENTIONS`](#code_conventions-env-var) — loads project conventions before implementing fixes or writing PR descriptions.

**Install:** `claude plugin install pr-workflow@jtsternberg` or `codex plugin add pr-workflow@jtsternberg`

#### 🛠️ [skill-tools](plugins/skill-tools)
Skills for creating and reviewing Claude Code skills, slash commands, and subagents.

**Skills:** `create-slash-command`, `create-subagent`, `review-skill`, `review-slash-command`

**Install:** `claude plugin install skill-tools@jtsternberg`

#### 📦 [beads-workflow](plugins/beads-workflow)
Work through beads epics from start to completion with automatic PR creation.

**Skills:** `tackle-epic`, `fix-findings-beads-tasks`

The skills are dual-harness compatible, but this repository currently offers the plugin only through its Claude Code catalog.

**Dependencies:** Requires [beads](https://github.com/steveyegge/beads)

**Supports:** [`CODE_CONVENTIONS`](#code_conventions-env-var) — loads project conventions before implementation work or fixing findings.

**Install:** `claude plugin install beads-workflow@jtsternberg`

#### 🤝 [handoff](plugins/handoff)
Create handoff documents to preserve context between Claude Code sessions.

**Skills:** `handoff`, `pickup-handoff`

**Install:** `claude plugin install handoff@jtsternberg`

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

## CODE_CONVENTIONS env var

Some plugins check for a `CODE_CONVENTIONS` environment variable pointing to a project-specific conventions file (e.g., patterns learned from past PR reviews). If set, the file is loaded before implementation work begins — helping avoid known anti-patterns and respect project-specific gotchas.

**Setup:** Add to your project's `.claude/settings.json`:

```json
{
  "env": {
    "CODE_CONVENTIONS": "docs/review-conventions.md"
  }
}
```

The file is plain markdown — no special format required. If the env var is unset, plugins behave as normal.

**Supported by:** [pr-workflow](#-pr-workflow), [beads-workflow](#-beads-workflow)

---

## 🔧 Development

### Clone the Repository

```bash
git clone https://github.com/jtsternberg/claude-plugins.git
cd claude-plugins
```

### Install the Marketplace Locally

Claude Code:

```bash
claude plugin marketplace add /path/to/claude-plugins
```

Codex:

```bash
codex plugin marketplace add /path/to/claude-plugins
```

### Install a Plugin from the Local Marketplace

Claude Code plugins:

```bash
claude plugin install <plugin-name>@jtsternberg
```

For Codex, choose a plugin that appears in the Codex-native catalog:

```bash
codex plugin add <plugin-name>@jtsternberg
```

### Repository Structure

```
.claude-plugin/
└── marketplace.json     # Claude Code catalog
.agents/plugins/
└── marketplace.json     # Codex-native catalog
plugins/
└── <plugin-name>/       # Each plugin in its own directory
    ├── .claude-plugin/plugin.json  # Claude/shared manifest
    ├── .codex-plugin/plugin.json   # Codex-native manifest (when published)
    ├── skills/<skill>/SKILL.md
    ├── hooks/           # Hook scripts (optional)
    └── README.md
```

For the current install commands, invocation conventions, and per-plugin
support boundary, see the [Codex compatibility guide](docs/codex/compatibility.md).
Detailed probe logs and historical decisions are kept separately in the
[Codex research archive](docs/codex/README.md). Maintainers shipping a plugin
change should use the [dual-harness release guide](docs/codex/release.md).

---

## Contributing

Contributions are welcome! To add a new plugin:

1. Fork this repository
2. Create a new directory under `plugins/`
3. Add its manifest and reusable workflows under `skills/<name>/SKILL.md`
4. Register it in the catalog for each harness it supports
5. Validate every skill against the repository's dual-harness contract
6. Update this README and the [support matrix](docs/codex/compatibility.md#plugin-support-matrix)
7. Submit a pull request

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Acknowledgments

Thanks to [bvdr/claude-plugins](https://github.com/bvdr/claude-plugins) for inspiration.
