---
name: fetch-docs
description: "Pulls a URL's raw content into a local file so Claude reads the authoritative source instead of WebFetch's summary. Use when the user wants docs, a page, or an API reference grounded in what the source actually says — not what a small-model pass thinks the page says. Works on any http/https URL; optional HTML→markdown conversion."
when_to_use: |
  Use when the user says any of:
  "fetch the docs", "fetch this URL raw", "fetch this page",
  "grab the raw page", "pull this URL without summarizing",
  "read this URL directly", "I want the full page, not a summary",
  "fetch-docs <url>", "read the actual docs at <url>".
  Also use proactively whenever you're about to call WebFetch on a docs
  page, API reference, README, or changelog — fetch-docs is strictly more
  grounded because the full source lands in a file you can Read.
allowed-tools: "Bash(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh *) Bash(curl *) Bash(npx *) Read"
---

# fetch-docs

WebFetch summarizes. This skill gets you the raw page.

When Claude Code calls WebFetch, a small-model pass filters the page through the user's prompt and drops specifics — exact flag names, enum values, edge-case prose. `fetch-docs` skips that step entirely: it `curl`s the URL into `/tmp/` and returns the file path.

**Do not Read the file by default.** The point of landing it on disk is to keep it out of context until the user actually asks about the content. Return the path and stop. If a follow-up turn asks what the docs say, Read it then.

## Prerequisites

```!
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh --check
```

(The check runs through the script rather than an inline `(cmd && echo) || echo` one-liner — a compound command like that trips Claude Code's shell-operator permission gate, whereas the script invocation is covered by this skill's `allowed-tools`.)

`curl` is required for every call. `npx` (with Node) is only needed when `--md` is passed *and* the URL returns HTML. Markdown-native URLs skip the conversion pipeline entirely. `agent-browser` is optional and only used by `--render` (see below) — the script never installs it.

## The default: raw HTML

```bash
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>")
```

Outputs `/tmp/fetch-docs-<slug>.html`. Claude reads HTML natively — no conversion needed to extract exact flag names, enum values, or code fences. This is the purest "bypass WebFetch" path and the one to prefer when fidelity matters more than readability.

## Markdown-native URLs (automatic)

Some docs sites publish `.md` alongside HTML (e.g. `https://code.claude.com/docs/en/skills.md`, raw GitHub READMEs), or author in `.mdx`/`.mdoc` (Astro/Starlight, Cloudflare docs, and most modern docs sites). The script detects them two ways:

1. URL path ends in `.md`, `.markdown`, `.mdx`, or `.mdoc` (query strings and fragments are ignored).
2. Response `Content-Type` header is `text/markdown` or `text/x-markdown`.

Either way, the file is saved as `.md` and the conversion pipeline is skipped. `--md` becomes a no-op on markdown sources — no round-trip loss.

## HTML → markdown (`--md`)

When the source is HTML and you want markdown:

```bash
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --md)
```

Pipeline: `readability-cli` extracts the article body (strips `<script>`, `<style>`, navbar, footer, sidebar), then `turndown-cli` converts the cleaned HTML to markdown. The script prefers PATH-installed binaries and falls back to `npx -y` — so there's nothing required to `npm install`, but `npx` adds ~3s of overhead per call (even with a warm cache).

### When you see the npx-fallback tip, offer to install

When the script uses the npx fallback for `--md`, it emits this line to stderr (visible in your Bash tool result):

```
fetch-docs: tip — npx fallback in use; 'npm i -g readability-cli turndown-cli' makes --md ~6× faster
```

Rule: **on the second time you see this tip in a session**, surface it to the user and offer to install. The first `--md` call is a one-off; the second proves the user is doing enough of this that the speedup is worth the install. On the first tip, stay silent.

When you do surface it, say something like:

> FYI — these `--md` calls are each taking ~4s because the binaries aren't installed globally. Installing them drops the time to ~0.7s (about 6× faster):
>
> ```bash
> npm i -g readability-cli turndown-cli
> ```
>
> Want me to run that?

**Never run `npm i -g` without explicit user consent.** Global npm state is shared machine-wide; it's not reversible for the user without them noticing. If they say yes, run it and continue. If they decline or ignore the offer, do not bring it up again in this session — even on subsequent tips.

### Reader-mode caveat

The reader-mode extraction is opinionated — it removes page chrome by design. If the user needs truly unfiltered HTML, drop `--md` and read the raw file.

## JS-rendered pages (`--render`)

`curl` fetches the raw HTML *before* any JavaScript runs. For client-rendered sites (React/Vue/Svelte SPAs — many API references, dashboards, and app-style docs), that raw HTML is just an empty shell like `<div id="root"></div>`, with the real content injected by JS that never executed. `curl` can't see it; neither can WebFetch reliably.

`--render` closes that gap. It fetches through a real headless browser ([`agent-browser`](https://github.com/vercel-labs/agent-browser)) instead of `curl`, waits for the page to settle, then captures the fully-rendered DOM:

```bash
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --render)
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --render --md)   # render, then convert to markdown
```

This is a **fallback tier, not the default.** Reach for it only when the cheaper paths come up empty:

1. **Plain `curl`** (default) — instant, zero deps. Works for static/SSR pages.
2. **`.md` sidecar** (automatic) — many modern docs sites publish markdown alongside HTML; the script detects and prefers it for free.
3. **`--render`** — only when 1 and 2 yield an empty shell, *and* `agent-browser` is installed.

### When to escalate to `--render`

- The script emits this stderr hint after a plain fetch when it detects an empty SPA shell **and** `agent-browser` is on PATH:

  ```
  fetch-docs: tip — this page looks client-rendered (empty SPA shell, ~NNN chars of visible text). agent-browser is installed; re-run with --render to capture the JS-rendered DOM.
  ```

  When you see it, re-run the same URL with `--render`.

- You don't see the hint but you Read a fetched HTML file and it's an empty shell / says "Loading..." → re-run with `--render` if `agent-browser` is installed.

### If `agent-browser` isn't installed

`--render` exits 1 with install guidance (`npm install -g agent-browser` or `brew install agent-browser`). **Never run that install without explicit user consent** — same rule as the `--md` global-install offer. Offer it, and if they decline, fall back to WebFetch for that one page. The script will not install anything on its own.

### Cost vs. fidelity

`--render` launches a headless Chrome and waits for network idle, so it's measured in seconds, not the sub-second `curl` path. Use it for the pages that genuinely need it — not as a blanket replacement. Output caches like any other fetch (same `--ttl` rules, same `/tmp/` path).

## Custom slug

```bash
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --slug=my-name)
```

Defaults to a 12-char hash of the URL (`/tmp/fetch-docs-4dc77b8f88a3.md`). Override with `--slug=<name>` for readable paths (`/tmp/fetch-docs-my-name.md`) when you'll reference the file across multiple turns.

## Cache behavior

Default TTL is 24h. A second call with the same URL within 24h returns the cached path instantly without refetching. Override:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --ttl=0       # force refetch
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --ttl=3600    # 1h cache
```

Raw, converted, and rendered outputs cache separately: a plain fetch writes `<slug>.html`; `--md` writes `<slug>.md`; `--render` writes `<slug>.rendered.html` (and `--render --md` writes `<slug>.rendered.md`). They coexist in `/tmp/` and never overwrite each other — so a cheap curl fetch of a URL can't satisfy a later `--render` of the same URL with its stale empty shell.

## Output conventions

Files land in `/tmp/fetch-docs-<slug>.<ext>`. macOS clears `/tmp/` periodically; no explicit cleanup required. For a manual sweep:

```bash
rm /tmp/fetch-docs-*
```

This mirrors the `/tmp/` pattern used by the [`work-with-media`](../../../work-with-media/shared/output-conventions.md) plugin so related tooling stays consistent.

## Important guidelines

1. **Quote URLs plainly** — double quotes, no backslashes before `?` or `&`. Zsh does not strip backslashes inside double quotes, so `"https://x.com/docs\?v\=2"` passes literal backslashes through to `curl`, which then hits the wrong URL. This is the same gotcha the `yt-dlp` skill flags.

2. **`--md` is a no-op on markdown sources.** If the URL returns markdown (by path or `Content-Type`), the script stores `.md` regardless of `--md`. Don't try to "force HTML output" on a markdown source — just read the `.md`.

3. **Authenticated URLs are out of scope for v1.** No cookie forwarding, no headers, no auth flags. Use `curl` directly for those. (If you need auth *and* JS rendering, `agent-browser` has its own profile/cookie/header flags — call it directly rather than through this skill.)

4. **Reader-mode transforms content.** `readability-cli` strips page chrome. If the user explicitly needs the full page (e.g. to inspect navigation or ads), omit `--md` and read the raw HTML.

5. **Prefer this over WebFetch for docs-style reads.** Any time fidelity matters — exact flag names, enum tables, versioned syntax — `fetch-docs` gives Claude the source. Save WebFetch for "what's the TLDR of this blog post" where a filtered pass is fine.

## Troubleshooting

- **Non-200 responses** — The script fails loudly (`fetch-docs: HTTP 404 for <url>`, exit 1). Check the URL; if it requires auth, this skill can't fetch it.
- **Empty body** — Some sites return 200 with no body when they detect a bot. Try a different URL or pass a User-Agent via direct `curl` as a fallback.
- **Page looks empty or says "Loading..."** — The docs site is client-rendered (React/Vue/Svelte SPA). `curl` fetches the raw HTML before JS executes, so there's no content for readability to extract. Common on Anthropic's and other modern docs sites. Work around, cheapest first: (1) find a raw markdown URL for the same page (many docs sites publish `.md` alongside HTML at `/docs/foo.md`); (2) if `agent-browser` is installed, re-run with `--render` to capture the JS-rendered DOM (see "JS-rendered pages" above); (3) fall back to WebFetch for this one page.
- **`readability-cli could not extract an article`** — The page isn't article-shaped (SPA landing pages, product pages). The script runs `readability-cli -l exit` by design, which fails fast rather than emitting CSS-leaked garbage. Drop `--md` and work with the raw HTML, or call `readability-cli` directly with `-l keep` if you really want the best-effort output.
- **Cache returned stale content** — Pass `--ttl=0` to force a refetch.
- **Content-Type misdetection** — If a site serves markdown with `Content-Type: text/plain` *and* the URL has no markdown extension, the script treats it as HTML. (URLs ending in `.md`/`.markdown`/`.mdx`/`.mdoc` are caught by path regardless of Content-Type — e.g. raw.githubusercontent.com `.mdx` files, which it serves as `text/plain`.) Work around: use a URL with a markdown extension in the path, or skip `--md` and treat the raw file as text.
- **`npx` cold-start is slow** — First `--md` call pulls `readability-cli` and `turndown-cli` into npx's cache. Subsequent calls are fast. Nothing to install globally.
