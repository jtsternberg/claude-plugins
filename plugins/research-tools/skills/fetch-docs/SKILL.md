---
name: fetch-docs
description: Pulls a URL's raw content into a local file so Claude reads the authoritative source instead of WebFetch's summary. Use when the user wants docs, a page, or an API reference grounded in what the source actually says — not what a small-model pass thinks the page says. Works on any http/https URL; optional HTML→markdown conversion.
when_to_use: |
  Use when the user says any of:
  "fetch the docs", "fetch this URL raw", "fetch this page",
  "grab the raw page", "pull this URL without summarizing",
  "read this URL directly", "I want the full page, not a summary",
  "fetch-docs <url>", "read the actual docs at <url>".
  Also use proactively whenever you're about to call WebFetch on a docs
  page, API reference, README, or changelog — fetch-docs is strictly more
  grounded because the full source lands in a file you can Read.
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh *) Bash(curl *) Bash(npx *) Read
---

# fetch-docs

WebFetch summarizes. This skill gets you the raw page.

When Claude Code calls WebFetch, a small-model pass filters the page through the user's prompt and drops specifics — exact flag names, enum values, edge-case prose. `fetch-docs` skips that step entirely: it `curl`s the URL into `/tmp/`, returns the file path, and you `Read` it like any other file.

## Prerequisites

```!
(command -v curl >/dev/null 2>&1 && echo "curl: OK ($(curl --version | head -1))") || echo "curl: NOT INSTALLED (required)"
(command -v npx >/dev/null 2>&1 && echo "npx: OK ($(npx --version))") || echo "npx: NOT INSTALLED (only needed for --md on HTML sources; markdown sources skip the pipeline)"
```

`curl` is required for every call. `npx` (with Node) is only needed when `--md` is passed *and* the URL returns HTML. Markdown-native URLs skip the conversion pipeline entirely.

## The default: raw HTML

```bash
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>")
```

Outputs `/tmp/fetch-docs-<slug>.html`. Claude reads HTML natively — no conversion needed to extract exact flag names, enum values, or code fences. This is the purest "bypass WebFetch" path and the one to prefer when fidelity matters more than readability.

## Markdown-native URLs (automatic)

Some docs sites publish `.md` alongside HTML (e.g. `https://code.claude.com/docs/en/skills.md`, raw GitHub READMEs). The script detects them two ways:

1. URL path ends in `.md` or `.markdown` (query strings and fragments are ignored).
2. Response `Content-Type` header is `text/markdown` or `text/x-markdown`.

Either way, the file is saved as `.md` and the conversion pipeline is skipped. `--md` becomes a no-op on markdown sources — no round-trip loss.

## HTML → markdown (`--md`)

When the source is HTML and you want markdown:

```bash
file=$(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh "<url>" --md)
```

Pipeline: `readability-cli` extracts the article body (strips `<script>`, `<style>`, navbar, footer, sidebar), then `turndown-cli` converts the cleaned HTML to markdown. Both run through `npx -y` so there's nothing to `npm install`; they just take a few extra seconds on first use while npx fetches them.

The reader-mode extraction is opinionated — it removes page chrome by design. If the user needs truly unfiltered HTML, drop `--md` and read the raw file.

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

Raw and converted outputs cache separately: fetching `<url>` without `--md` writes `<slug>.html`; with `--md` writes `<slug>.md`. Both can coexist in `/tmp/`.

## Output conventions

Files land in `/tmp/fetch-docs-<slug>.<ext>`. macOS clears `/tmp/` periodically; no explicit cleanup required. For a manual sweep:

```bash
rm /tmp/fetch-docs-*
```

This mirrors the `/tmp/` pattern used by the [`work-with-media`](../../../work-with-media/shared/output-conventions.md) plugin so related tooling stays consistent.

## Important guidelines

1. **Quote URLs plainly** — double quotes, no backslashes before `?` or `&`. Zsh does not strip backslashes inside double quotes, so `"https://x.com/docs\?v\=2"` passes literal backslashes through to `curl`, which then hits the wrong URL. This is the same gotcha the `yt-dlp` skill flags.

2. **`--md` is a no-op on markdown sources.** If the URL returns markdown (by path or `Content-Type`), the script stores `.md` regardless of `--md`. Don't try to "force HTML output" on a markdown source — just read the `.md`.

3. **Authenticated URLs are out of scope for v1.** No cookie forwarding, no headers, no auth flags. Use `curl` directly for those.

4. **Reader-mode transforms content.** `readability-cli` strips page chrome. If the user explicitly needs the full page (e.g. to inspect navigation or ads), omit `--md` and read the raw HTML.

5. **Prefer this over WebFetch for docs-style reads.** Any time fidelity matters — exact flag names, enum tables, versioned syntax — `fetch-docs` gives Claude the source. Save WebFetch for "what's the TLDR of this blog post" where a filtered pass is fine.

## Troubleshooting

- **Non-200 responses** — The script fails loudly (`fetch-docs: HTTP 404 for <url>`, exit 1). Check the URL; if it requires auth, this skill can't fetch it.
- **Empty body** — Some sites return 200 with no body when they detect a bot. Try a different URL or pass a User-Agent via direct `curl` as a fallback.
- **Page looks empty or says "Loading..."** — The docs site is client-rendered (React/Vue/Svelte SPA). `curl` fetches the raw HTML before JS executes, so there's no content for readability to extract. Common on Anthropic's and other modern docs sites. Work around: find a raw markdown URL for the same page (many docs sites publish `.md` alongside HTML at `/docs/foo.md`), or fall back to WebFetch for this one page.
- **`readability-cli could not extract an article`** — The page isn't article-shaped (SPA landing pages, product pages). The script runs `readability-cli -l exit` by design, which fails fast rather than emitting CSS-leaked garbage. Drop `--md` and work with the raw HTML, or call `readability-cli` directly with `-l keep` if you really want the best-effort output.
- **Cache returned stale content** — Pass `--ttl=0` to force a refetch.
- **Content-Type misdetection** — If a site serves markdown with `Content-Type: text/plain`, the script treats it as HTML. Work around: use a URL with `.md` in the path, or skip `--md` and treat the raw file as text.
- **`npx` cold-start is slow** — First `--md` call pulls `readability-cli` and `turndown-cli` into npx's cache. Subsequent calls are fast. Nothing to install globally.
