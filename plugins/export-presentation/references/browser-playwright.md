# Playwright

Browser automation commands for exporting slides via [Playwright](https://playwright.dev/) CLI or MCP.

## Setup

### CLI

Verify installation:

```bash
which playwright || npx playwright --version
```

If using `npx`, ensure browsers are installed:

```bash
npx playwright install chromium
```

### MCP

Check for Playwright MCP tools in the tool list (tool names vary by MCP server implementation).

## CLI Approach

Playwright's CLI can take screenshots directly, but for multi-slide navigation, a script is more practical.

### Screenshot Script

Create a temporary script and run it with Playwright:

```javascript
// export-slides.mjs
import { chromium } from 'playwright';

const url = process.argv[2];
const slideCount = parseInt(process.argv[3]);
const outDir = process.argv[4] || 'screenshots';

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });

await page.goto(url);
await page.waitForTimeout(2000); // Wait for fonts and JS

const { mkdirSync } = await import('fs');
mkdirSync(outDir, { recursive: true });

for (let i = 1; i <= slideCount; i++) {
  const pad = String(i).padStart(2, '0');
  await page.screenshot({ path: `${outDir}/slide-${pad}.png`, fullPage: false });

  if (i < slideCount) {
    await page.keyboard.press('ArrowRight');
    await page.waitForTimeout(500); // Transition time
  }
}

await browser.close();
console.log(`Captured ${slideCount} slides to ${outDir}/`);
```

Run with:

```bash
node export-slides.mjs <url> <slide-count> [output-dir]
```

## MCP Approach

If using Playwright via MCP, the commands map to MCP tool calls:

1. **Navigate:** Use the MCP navigate tool with the presentation URL
2. **Set viewport:** Use the MCP resize/viewport tool for 1920x1080
3. **Screenshot:** Use the MCP screenshot tool, save each slide
4. **Advance:** Use the MCP keyboard tool to press ArrowRight
5. **Wait:** Pause 0.5s between slides for transitions

The exact tool names depend on the Playwright MCP server implementation.

## Notes

- Playwright runs headless by default (no visible browser window)
- The `fullPage: false` option captures only the viewport (not scrollable content), which is correct for slides
- Viewport is set explicitly to 1920x1080 via `newPage({ viewport: ... })`
- Playwright handles font loading more reliably than raw CDP — `page.waitForTimeout(2000)` is usually sufficient
