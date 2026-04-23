# cmux embedded browser

cmux ships a browser surface that you can drive programmatically — navigate, click, type, snapshot the DOM, take screenshots, manipulate cookies and storage, evaluate JS. Think Playwright/Puppeteer, but with a cmux surface as the target instead of a headless Chrome.

This reference is loaded on demand. Main SKILL.md keeps only the natural-language triggers for browser work — read this file when an agent task actually involves the browser.

## When to use a browser surface

- Preview a locally-running web app and interact with it.
- Automate a sign-in flow or a multi-step form as part of an agent task.
- Scrape or verify rendered output of a page (prefer `snapshot` over manual parsing).
- Drive an app that's running inside an SSH workspace — the browser pane transparently routes through the remote network (see [ssh.md](ssh.md)).

## Commands at a glance

Always get the authoritative list from the running build:

```
cmux browser --help
```

Grouped for navigation (run `cmux browser <subcommand> --help` for flags):

- **Pane lifecycle**: `open`, `open-split`, `new`, `identify`
- **Navigation**: `navigate` / `goto`, `back`, `forward`, `reload`, `url` / `get-url`
- **Seeing the page**: `snapshot` (DOM + a11y — the default agent tool), `screenshot` (PNG for humans), `get <url|title|text|html|value|attr|count|box|styles>`
- **Interacting**: `click`, `dblclick`, `hover`, `focus`, `check`, `uncheck`, `scroll-into-view`, `type`, `fill`, `press`, `keydown`, `keyup`, `select`, `scroll`
- **Locators**: `find <role|text|label|placeholder|alt|title|testid|first|last|nth>`, `is <visible|enabled|checked>`
- **Waits**: `wait [--selector|--text|--url-contains|--load-state|--function] [--timeout-ms <n>]`
- **Evaluation**: `eval <js>`, `addinitscript`, `addscript`, `addstyle`
- **State**: `cookies <get|set|clear>`, `storage <local|session> <get|set|clear>`, `state <save|load> <path>`
- **Page plumbing**: `frame`, `dialog`, `download`, `tab <new|list|switch|close|<index>>`, `highlight`
- **Streams**: `console <list|clear>`, `errors <list|clear>`

## Addressing a browser surface

Most subcommands need a target surface. Two equivalent forms:

```
cmux browser --surface <ref> <subcommand> ...
cmux browser <surface-ref> <subcommand> ...
```

`open` / `open-split` / `new` / `identify` work without an explicit surface — they create or introspect one.

## Key patterns

### `snapshot` first, `screenshot` only for humans

- `browser snapshot` returns a structured DOM + accessibility tree you can reason about in text. **This is the default for agent-driven logic.**
- `browser screenshot` produces a PNG. Use this only when you're handing visual output to a human to inspect.

Agents often reach for `screenshot` reflexively — it's the wrong default. Snapshots are text, diffable, and cheap.

### `--snapshot-after` chains a read onto every mutation

Most mutating subcommands — `click`, `type`, `fill`, `navigate`, `press`, `select`, `scroll`, etc. — accept `--snapshot-after`. Use it. You get the post-action DOM back in the same round-trip, no separate `snapshot` call needed.

### Wait for conditions, not sleeps

`browser wait` supports `--selector`, `--text`, `--url-contains`, `--load-state <interactive|complete>`, or `--function <js>`. Combine with `--timeout-ms` / `--timeout` to bound the wait. Never wall-clock-sleep between actions if you can express the condition declaratively.

### Reading the page

- **DOM / a11y content**: `browser snapshot [--compact] [--max-depth <n>] [--selector <css>] [--interactive] [--cursor]`
- **Specific text / HTML / attribute**: `browser get text|html|value|attr|count|box|styles [--selector <css>] [--property <name>]`
- **Predicates**: `browser is visible|enabled|checked --selector <css>`
- **Find elements by role / label / testid**: `browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...`

### Cookies and storage

`cookies get|set|clear` and `storage local|session get|set|clear` take the typical shape of flags (`--name`, `--value`, `--url`, `--domain`, `--path`, `--expires`, `--secure`, `--all`). Use for session seeding, auth-state persistence, or cleanup between tests.

## Natural-language quick reference

| User says | cmux command |
|-----------|--------------|
| "open localhost:3000 in the browser pane" | `cmux browser open http://localhost:3000` |
| "click the submit button" | `cmux browser click --selector 'button[type=submit]' --snapshot-after` |
| "what does the page look like right now?" (agent-reading) | `cmux browser snapshot` |
| "show me what the page looks like" (human-viewing) | `cmux browser screenshot --out /tmp/page.png` |
| "wait until the dashboard loads" | `cmux browser wait --selector '#dashboard' --timeout-ms 10000` |
| "type into the email field" | `cmux browser fill --selector 'input[name=email]' me@example.com --snapshot-after` |
| "what did the console log?" | `cmux browser console list` |

## Browser in an SSH workspace

Inside a workspace created by `cmux ssh`, browser panes route their HTTP / WebSocket traffic through the remote host's network. Type `localhost:3000` in the URL bar and you're looking at the dev server on the remote box — no `-L` port forwarding. Each remote workspace has an isolated cookie store. See [ssh.md](ssh.md).
