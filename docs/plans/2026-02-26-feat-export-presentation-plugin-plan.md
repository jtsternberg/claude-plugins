---
title: "feat: Add export-presentation plugin"
type: feat
status: completed
date: 2026-02-26
---

# feat: Add export-presentation plugin

## Overview

Create a new `export-presentation` plugin (sibling to `slides-presentation`) that exports HTML slide presentations to PDF or PNG screenshots. The plugin uses progressive browser tool discovery to work across different environments, and assembles lossless PDFs from per-slide screenshots.

## Problem Statement / Motivation

After building a slide deck with the `slides-presentation` plugin, users need to share it as a PDF or image set for email, Slack, archiving, or printing. Currently this requires manual browser print-to-PDF (which often paginates wrong) or ad-hoc scripting. This plugin automates the full export workflow.

## Proposed Solution

A skill-based plugin that:
1. Detects the best available browser automation tool (progressive disclosure)
2. Navigates each slide and captures a full-viewport screenshot at 1920x1080
3. Assembles screenshots into a lossless PDF (default) or exports as images only

### Browser Tool Priority

| Priority | Tool | Detection | Reference Doc |
|----------|------|-----------|---------------|
| 1 | agent-browser CLI | `which agent-browser` | `references/browser-agent-browser.md` |
| 2 | Claude in Chrome MCP | MCP tool availability | `references/browser-claude-in-chrome.md` |
| 3 | Playwright CLI/MCP | `which playwright` or MCP tool availability | `references/browser-playwright.md` |
| 4 | Chrome DevTools MCP | MCP tool availability | `references/browser-chrome-devtools.md` |
| 5 | None | -- | Error with installation instructions |

### PDF Assembly Priority

| Priority | Tool | Detection | Command |
|----------|------|-----------|---------|
| 1 | img2pdf | `python3 -c "import img2pdf"` | `python3 -c "import img2pdf, os; ..."` |
| 2 | ImageMagick | `which magick` or `which convert` | `magick *.png output.pdf` |

**Why img2pdf first:** It embeds PNGs losslessly. Pillow's `Image.save(save_all=True)` uses JPEG compression by default, producing blurry results. ImageMagick works but img2pdf is purpose-built.

## Technical Considerations

### Security

- Local HTTP server MUST bind to `127.0.0.1` only (not `0.0.0.0`)
- Use a dynamic/random available port to avoid conflicts
- Server serves only the directory containing the HTML file
- PID tracked for cleanup via trap handler

### Viewport

- Screenshots at 1920x1080 (16:9, matching typical presentation ratio)
- Per-tool reference docs specify how to set viewport for that tool

### Slide Navigation

- Parse `data-slide` attributes from HTML to determine slide count
- Scoped to slides-presentation template format (noted as limitation)
- 0.5s default sleep between slides for CSS transitions
- Initial page-load wait (1-2s) for fonts and JS to load

### Preflight Checks (before screenshots)

- Verify browser tool is functional
- Verify PDF assembler is available (for PDF mode)
- Verify input file exists and contains `data-slide` attributes
- Verify output path is writable

### Server Handling

- If input is a file path: automatically start `python3 -m http.server --bind 127.0.0.1 <port>` in the directory containing the HTML file
- If input is a URL: use directly, no server needed
- Track server PID; clean up on exit or failure

## File Structure

```
plugins/export-presentation/
├── .claude-plugin/
│   └── plugin.json
├── SKILL.md                              # Main skill with workflow
├── README.md                             # User-facing docs
├── references/
│   ├── browser-agent-browser.md          # agent-browser CLI commands
│   ├── browser-claude-in-chrome.md       # Claude in Chrome MCP commands
│   ├── browser-playwright.md             # Playwright CLI/MCP commands
│   ├── browser-chrome-devtools.md        # Chrome DevTools MCP commands
│   └── pdf-assembly.md                   # img2pdf + ImageMagick instructions
└── scripts/
    └── serve-local.sh                    # Start local HTTP server, output URL+PID
```

## Acceptance Criteria

### Core

- [x] Plugin directory at `plugins/export-presentation/` with `.claude-plugin/plugin.json`
- [x] `SKILL.md` with frontmatter (name, description with trigger keywords)
- [x] `README.md` with installation, requirements, usage, examples
- [x] Plugin registered in `.claude-plugin/marketplace.json`

### SKILL.md Workflow

- [x] Step 1: Detect browser tool (priority order, load reference doc)
- [x] Step 2: Preflight checks (browser tool, PDF assembler, input validation)
- [x] Step 3: Resolve URL (auto-start secure local server if file path given)
- [x] Step 4: Count slides (parse `data-slide` attributes from HTML)
- [x] Step 5: Navigate & screenshot (per-tool instructions from reference doc, 1920x1080 viewport)
- [x] Step 6: Assemble output (PDF default via img2pdf/ImageMagick, or images-only)
- [x] Step 7: Clean up (stop server if started, remove temp screenshots unless images-only)

### Reference Docs

- [x] `references/browser-agent-browser.md` — open, press ArrowRight, screenshot --full, viewport config
- [x] `references/browser-claude-in-chrome.md` — navigate, computer/screenshot, keyboard commands
- [x] `references/browser-playwright.md` — CLI and MCP variants, screenshot commands
- [x] `references/browser-chrome-devtools.md` — CDP commands for navigation and screenshots
- [x] `references/pdf-assembly.md` — img2pdf script, ImageMagick fallback, output naming

### Scripts

- [x] `scripts/serve-local.sh` — starts server on 127.0.0.1 with available port, outputs URL and PID, serves from HTML file's directory

### Cross-References

- [x] `slides-presentation/README.md` updated to reference export-presentation as companion plugin
- [x] `export-presentation/README.md` references slides-presentation for creating decks

### Output Behavior

- [x] Default: PDF output at `<input-basename>.pdf` in same directory as HTML
- [x] Images-only mode: screenshots directory preserved, no PDF assembly
- [x] Progress feedback during multi-slide capture
- [x] Summary line on completion (e.g., "Exported 20 slides to presentation.pdf")

## Dependencies & Risks

| Risk | Mitigation |
|------|------------|
| No browser tool installed | Clear error message with installation links for each tool |
| img2pdf not installed | Fall back to ImageMagick; if neither available, error with instructions |
| Port 8000 in use | Dynamic port selection in serve-local.sh |
| Orphaned server process | PID tracking + trap handler in serve-local.sh |
| Screenshots mid-transition | 0.5s sleep after each navigation; initial page-load wait |
| Fonts not loaded | Initial 1-2s wait after page open; note limitation for offline use |

## Scope Notes

- **In scope:** Exporting slides-presentation template HTML to PDF/images
- **Future scope:** PPTX export, reveal.js support, partial slide range export
- **Out of scope:** Exporting arbitrary HTML pages, video export

## References

### Internal

- Sibling plugin: `plugins/slides-presentation/` (structure reference)
- Real-world workflow: `/Users/JT/Code/beads-talk/GENERATE-SCREENSHOTS-AND-PDF.md`
- Marketplace: `.claude-plugin/marketplace.json`

### External

- [Claude Code Skills Best Practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [agent-browser CLI](https://github.com/anthropics/agent-browser)
