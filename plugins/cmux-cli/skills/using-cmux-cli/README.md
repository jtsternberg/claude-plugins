# using-cmux-cli

Teaches a Claude Code agent how to drive [cmux](https://cmux.sh) — the macOS terminal multiplexer / workspace manager — through its `cmux` CLI. Tell Claude "open a terminal side-by-side so I can see both," "read what's happening in my other tab," or "ssh into box.example.com as a workspace," and it'll do the right thing.

## What it does

Gives Claude a working model of cmux's surface area — windows, workspaces, panes, surfaces, tabs, terminal I/O, the event stream, notifications, sidebar progress, the embedded browser, SSH workspaces, and tmux-compat commands — without mirroring a flag list that bitrots the moment cmux ships a new release. The skill resolves its context at load time via `cmux identify` and runs `cmux <cmd> --help` on demand. The CLI is always the source of truth.

## When to use it

- You want Claude to manage cmux splits, tabs, and workspaces based on natural-language requests.
- You want Claude to read or drive another pane/tab for you (gather context, send a command, verify output).
- You want Claude to surface progress in the cmux sidebar while doing long work, instead of spamming your terminal.
- You want Claude to wait for something — a build, another agent's turn — without burning a round-trip every few seconds polling for it.
- You want Claude to drive the embedded browser (navigate, click, snapshot DOM, etc.) or manage an SSH workspace where browser traffic routes through the remote box.

## Two workflows built in

**Open a side-by-side surface in the current window.** When you say "open a tab next to mine" or "new terminal side-by-side," the skill uses a bundled helper (`open-side-surface.sh`) that picks the right action based on the current layout: if an adjacent pane already exists, it adds the new surface as a tab inside that pane (reusing real estate); otherwise it creates a new pane column. Works for both terminal and browser surfaces.

**Find, read, and optionally drive another surface.** When you say "find the surface in my 'debug lindy' workspace that's hitting the 500 error," another bundled helper (`find-surface.sh`) locates the right surface by workspace name, title, or on-screen content — then the agent reads its screen, optionally sends commands, and verifies the result.

## Waiting and verifying, without polling

cmux emits a retained, replayable event stream, and the skill routes waiting through it rather than through screen-scraping loops. "Tell me when that finishes" becomes one blocking call that costs nothing while it waits. "Did that message actually get through?" becomes a measurement — the submission event carries an exact length, so a truncated or fragmented delivery is detected rather than assumed. The alternative, inferring both from what a terminal happens to be drawing, is what the reference documents as the fallback for when no event stream is available.

## Natural-language triggers

The skill activates on anything cmux-adjacent:

- "split this right" / "open a new tab next to mine" / "new terminal side-by-side"
- "read the terminal output from workspace 2" / "what's in the other pane?"
- "send `git status` to the other pane" / "run npm test in surface:3"
- "pin this tab" / "close tabs to the right" / "rename this workspace to 'build'"
- "ssh into box.example.com as a workspace" / "open a remote workspace named 'dev'"
- "show build progress in the sidebar" / "notify me when the build finishes"
- "use cmux's browser to open localhost:3000" / "click the submit button in the browser"

## What's in the bundle

- `SKILL.md` — the agent-facing playbook.
- `scripts/find-surface.sh` — locate a surface by workspace / title / content; JSON output for chaining.
- `scripts/open-side-surface.sh` — decide between `new-surface --pane <adjacent-UUID>` and `new-pane --direction right`, based on current layout.
- `references/targeting.md` — UUID guards, bulk-operation safety, and find/read/send workflows.
- `references/opening-surfaces.md` — visible placement, naming, readiness, caller recovery, and marking existing targets.
- `references/terminal-io.md` — screen interpretation, shell vs REPL submission, delivery forensics, and key handling.
- `references/command-reference.md` — command vocabulary, environment, sidebar metadata, mappings, and troubleshooting.
- `references/layouts.md` — split geometry and layout reproduction.
- `references/browser.md` — full embedded-browser automation reference (loaded on demand).
- `references/ssh.md` — `cmux ssh` remote workspace reference — relay daemon, browser routing, drag-drop, reconnect semantics (loaded on demand).
- `references/events.md` — the `cmux events` stream: full event catalog, payload shapes, and recipes for waiting on an agent's turn, confirming a send landed on the surface you meant, and resuming a watcher from a durable cursor (loaded on demand).
- `references/progress-loops.md` — sidebar progress-loop recipe — when an event beats a loop, the two-loop pattern (updater + exit detector), clear/notify pairing (loaded on demand).

The main `SKILL.md` keeps routing and core safeguards inline, with required read triggers for task-specific procedures. Agents load the matching references before acting. Claude Code resolves the dynamic context at load time; Codex runs those commands explicitly.

## Requirements

- **cmux.app** installed and running. The CLI talks to the app over a Unix socket (path reported by `cmux identify`). Without the app, the skill fails fast at load time.
- **`cmux` on PATH** — usually `/Applications/cmux.app/Contents/Resources/bin/cmux` after install.
- **`jq`** — required by the bundled scripts for JSON parsing. `brew install jq` on macOS.
