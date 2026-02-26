# Export Presentation Plugin

Export HTML slide presentations to PDF or PNG screenshots using browser automation.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install export-presentation@jtsternberg
```

## Requirements

**Browser automation tool (one of the following):**

| Tool | Type | How to get it |
|------|------|---------------|
| [agent-browser](https://github.com/anthropics/agent-browser) (recommended) | CLI | `npm install -g @anthropic/agent-browser` |
| Claude in Chrome | MCP server | Install the [Claude in Chrome](https://chromewebstore.google.com/detail/claude-in-chrome/) extension |
| [Playwright](https://playwright.dev/) | CLI or MCP | `npm install -g playwright` |
| Chrome DevTools | MCP server | Connect via Chrome DevTools Protocol |

**PDF assembly (for PDF output):**

| Tool | Priority | How to get it |
|------|----------|---------------|
| [img2pdf](https://pypi.org/project/img2pdf/) (preferred) | 1st | `pip install img2pdf` |
| [ImageMagick](https://imagemagick.org/) | Fallback | `brew install imagemagick` (macOS) |

img2pdf is preferred because it embeds PNGs losslessly. ImageMagick works but may apply compression.

## Description

Companion to the [slides-presentation](../slides-presentation/) plugin. After building a slide deck, use this plugin to export it as a PDF for sharing via email, Slack, or for archiving — or as individual PNG screenshots.

## Usage

The skill triggers when you:
- "Export this presentation to PDF"
- "Take screenshots of each slide"
- "Convert my slides to images"
- "Generate a PDF from the presentation"

You can provide either a **file path** (a local server is started automatically) or a **URL**.

## How It Works

1. **Detect tool** — Finds the best available browser automation tool
2. **Preflight** — Validates input, counts slides, checks PDF assembler
3. **Serve** — Starts a local server if given a file path (automatic)
4. **Capture** — Opens presentation, screenshots each slide at 1920x1080
5. **Assemble** — Combines screenshots into a lossless PDF (or keeps as images)
6. **Clean up** — Stops server, removes temp files, reports results

## Output

- **Default:** `<presentation-name>.pdf` in the same directory as the HTML file
- **Images-only:** A `screenshots/` directory with `slide-01.png`, `slide-02.png`, etc.

## Example

```
User: "Export /path/to/beads-talk/presentation.html to PDF"

Claude: Detects agent-browser, starts local server, captures 11 slides,
        assembles lossless PDF → beads-talk/presentation.pdf
```

## Related

- [slides-presentation](../slides-presentation/) — Build the HTML slide decks that this plugin exports

## Additional Documentation

- [SKILL.md](SKILL.md) — Complete workflow and guidelines
- [references/](references/) — Per-tool browser automation guides and PDF assembly instructions
- [scripts/serve-local.sh](scripts/serve-local.sh) — Local HTTP server utility
