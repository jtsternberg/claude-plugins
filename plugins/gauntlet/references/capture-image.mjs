#!/usr/bin/env node
// Reference image harness: screenshot one element (or the full page) to a PNG.
//   node capture.mjs --url <url> [--selector <css>] [--width 1440] [--height 900] --out <file.png>
// Needs Playwright where it runs: `npm i -D playwright && npx playwright install chromium`.
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
if (!args.url || !args.out) { console.error('capture: --url and --out are required'); process.exit(2); }
let chromium;
try { ({ chromium } = await import('playwright')); }
catch { console.error('capture: playwright is not installed here (npm i -D playwright)'); process.exit(3); }
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: Number(args.width ?? 1440), height: Number(args.height ?? 900) } });
  await page.goto(args.url, { waitUntil: 'networkidle' });
  if (args.selector) await page.locator(args.selector).first().screenshot({ path: args.out });
  else await page.screenshot({ path: args.out, fullPage: true });
} finally { await browser.close(); }
