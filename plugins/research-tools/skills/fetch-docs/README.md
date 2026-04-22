# fetch-docs

Gives Claude Code the full, unfiltered version of any docs page or article — so it answers from the actual source instead of a quick summary that might miss details.

## The problem this solves

When you ask Claude about a URL, it normally uses a built-in "fetch" tool that reads the page **through a summarizer first**. That summarizer is fast, but it drops things. Exact option names. Enum values. Edge cases in the fine print. You often won't notice until Claude confidently tells you something that's almost-but-not-quite right.

`fetch-docs` skips the summarizer. It downloads the page to your computer, and then Claude reads the full thing when you ask about it. Same accuracy as if you'd opened the page yourself and pasted it in.

## When to use it

Any time you want Claude grounded in what a page **actually says** — not a quick interpretation. Common cases:

- "Read the docs at [URL] and help me configure X"
- "Pull this changelog and tell me what changed in version 2"
- "Grab this API reference so we can write code against it"
- "Fetch this article and summarize it accurately"

If you're just asking for a casual TLDR of a blog post, Claude's regular WebFetch is fine. Reach for `fetch-docs` when details matter.

## Install

```bash
amskills install fetch-docs
```

That's it. Claude Code will pick up the skill automatically.

## How to use it

You don't need to remember a command. Just ask naturally:

- "fetch the docs at https://example.com/docs/getting-started"
- "read the actual page at https://example.com/faq, not a summary"
- "pull this URL raw: https://example.com/changelog"
- "grab the raw readme from https://github.com/foo/bar"

Claude will download the page and tell you where it saved it. Then ask follow-up questions like *"what does it say about authentication?"* or *"summarize the 'getting started' section"* and Claude will read the file and answer.

You can also type `/fetch-docs <url>` if you prefer slash commands.

## Getting a cleaner markdown version

By default, the page is saved exactly as the website sent it. If the page is HTML and you want a clean markdown version (easier to read, strips away navigation/ads/sidebars), ask Claude for the markdown version:

> "fetch this as markdown: https://example.com/article"

Behind the scenes, Claude adds a `--md` flag to the command. The first time you do this it may take a few seconds because it's downloading a small helper program on the fly. If you find yourself using the markdown version often, Claude will offer to install the helper permanently so future calls are ~6× faster. Say yes and it'll handle the install for you.

## What it can't do

- **Password-protected pages** — the skill doesn't log in for you. If a page requires authentication, this won't reach it.
- **Some modern docs sites** — sites built with frameworks like React sometimes load their content only after the page renders in a browser. `fetch-docs` reads the page like a simple downloader would, so those sites show up empty. Claude will tell you when this happens. For those, fall back to Claude's regular WebFetch or look for a "raw" or `.md` version of the same page (many docs sites publish both).

## Where the files go

Everything lands in your computer's `/tmp/` folder, which your Mac cleans up automatically over time. You don't have to manage anything. If you want to keep a permanent copy of a page, just tell Claude where to move it.

## Requirements

This skill works out of the box on both macOS and Linux. If you're asking for the markdown version (`--md`), you also need Node.js on your computer — most developer setups have it. If it's missing, Claude will tell you.
