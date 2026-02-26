---
name: export-presentation
description: Exports HTML slide presentations to PDF or PNG screenshots. Use when the user asks to export slides, convert a presentation to PDF, take slide screenshots, print a deck, or share a presentation as images. Companion to the slides-presentation plugin.
---

# Export Presentation

Export HTML slide presentations (built with `slides-presentation`) to PDF or PNG screenshots using browser automation.

## Workflow

### Step 1: Detect Browser Automation Tool

Check for available browser tools in this priority order. Use the **first one found** and read its reference doc for tool-specific commands:

| Priority | Tool | How to detect | Reference |
|----------|------|---------------|-----------|
| 1 | agent-browser CLI | `which agent-browser` | [references/browser-agent-browser.md](references/browser-agent-browser.md) |
| 2 | Claude in Chrome MCP | MCP tools `mcp__claude-in-chrome__*` available | [references/browser-claude-in-chrome.md](references/browser-claude-in-chrome.md) |
| 3 | Playwright | `which playwright` or `npx playwright --version`, or MCP tools available | [references/browser-playwright.md](references/browser-playwright.md) |
| 4 | Chrome DevTools MCP | MCP tools `mcp__chrome-devtools__*` available | [references/browser-chrome-devtools.md](references/browser-chrome-devtools.md) |

If **no browser tool is found**, stop and tell the user which tools are supported with links to install them. Recommend `agent-browser` as the simplest option.

Read the reference doc for the detected tool before proceeding — it contains the exact commands for navigation, screenshots, and viewport configuration.

### Step 2: Preflight Checks

Before starting the (slow) screenshot loop, validate everything upfront:

1. **Input exists** — verify the HTML file path or URL is accessible
2. **Slide count** — parse the HTML for `data-slide` attributes to count slides. If no `data-slide` attributes found, warn the user this may not be a slides-presentation deck
3. **PDF assembler** (if PDF mode) — check availability in order:
   - `python3 -c "import img2pdf"` (preferred — lossless PNG embedding)
   - `which magick` or `which convert` (ImageMagick fallback)
   - If neither available, warn and suggest installing: `pip install img2pdf`
4. **Output path** — verify the target directory is writable

For PDF assembly details, see [references/pdf-assembly.md](references/pdf-assembly.md).

### Step 3: Resolve URL

**If given a URL:** Use it directly. Skip to Step 4.

**If given a file path:** Start a local HTTP server automatically:

```bash
bash scripts/serve-local.sh /path/to/presentation.html
```

The script outputs the URL and PID. Use the URL for browser navigation. The PID is needed for cleanup in Step 7.

### Step 4: Count Slides

Read the HTML file and count `data-slide` attributes:

```bash
grep -c 'data-slide=' presentation.html
```

Or parse more precisely for `data-slide="N"` to get the exact count. Slides are zero-indexed (`data-slide="0"` through `data-slide="N-1"`), so slide count = max index + 1.

### Step 5: Navigate and Screenshot

Using the detected browser tool's commands (from its reference doc):

1. **Set viewport** to `1920x1080` (16:9, matching presentation aspect ratio)
2. **Open the URL** in the browser
3. **Wait 2 seconds** after page load for fonts and JavaScript to initialize
4. **Create a screenshots directory** (e.g., `screenshots/` in the output location)
5. **Screenshot the first slide** as `slide-01.png`
6. **For each remaining slide:**
   - Press `ArrowRight` to advance
   - Wait `0.5s` for the CSS transition to complete
   - Screenshot as `slide-NN.png` (zero-padded, 1-indexed filenames)

Report progress as you go (e.g., "Captured slide 5 of 20").

### Step 6: Assemble Output

**PDF mode (default):**

Assemble all screenshots into a single PDF. See [references/pdf-assembly.md](references/pdf-assembly.md) for the exact commands.

Output filename: `<input-basename>.pdf` in the same directory as the HTML file (or current directory if URL input).

**Images-only mode:**

If the user requested images only, skip PDF assembly. The screenshots directory is the final output.

### Step 7: Clean Up

1. **Stop the local server** if one was started in Step 3 (kill the PID)
2. **Remove temporary screenshots** if PDF mode (they're embedded in the PDF now)
3. **Report results** — print the output path and a summary:
   ```
   Exported 20 slides to presentation.pdf
   ```

## Limitations

- Designed for HTML presentations built with the `slides-presentation` template (uses `data-slide` attributes for navigation)
- Requires a browser automation tool — see Step 1 for supported options
- External fonts (Google Fonts) require internet connectivity during export
- Future: PPTX export, reveal.js support, partial slide range export

## Utility Scripts

- **`scripts/serve-local.sh <file.html>`** — Starts a local HTTP server bound to `127.0.0.1` on an available port. Outputs the full URL and server PID. Serves from the directory containing the HTML file.
