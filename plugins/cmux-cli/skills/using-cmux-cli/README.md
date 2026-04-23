# using-cmux-cli

Teaches a Claude Code agent how to drive [cmux](https://cmux.sh) — the macOS terminal multiplexer / workspace manager — through its `cmux` CLI. Tell Claude "open a terminal side-by-side so I can see both," "read what's happening in my other tab," or "ssh into box.example.com as a workspace," and it'll do the right thing.

## What it does

Gives Claude a working model of cmux's surface area — windows, workspaces, panes, surfaces, tabs, terminal I/O, notifications, sidebar progress, the embedded browser, SSH workspaces, and tmux-compat commands — without mirroring a flag list that bitrots the moment cmux ships a new release. The skill resolves its context at load time via `cmux identify` and runs `cmux <cmd> --help` on demand. The CLI is always the source of truth.

## When to use it

- You want Claude to manage cmux splits, tabs, and workspaces based on natural-language requests.
- You want Claude to read or drive another pane/tab for you (gather context, send a command, verify output).
- You want Claude to surface progress in the cmux sidebar while doing long work, instead of spamming your terminal.
- You want Claude to drive the embedded browser (navigate, click, snapshot DOM, etc.) or manage an SSH workspace where browser traffic routes through the remote box.

## Two workflows built in

**Open a side-by-side surface in the current window.** When you say "open a tab next to mine" or "new terminal side-by-side," the skill uses a bundled helper (`open-side-surface.sh`) that picks the right action based on the current layout: if an adjacent pane already exists, it adds the new surface as a tab inside that pane (reusing real estate); otherwise it creates a new pane column. Works for both terminal and browser surfaces.

**Find, read, and optionally drive another surface.** When you say "find the surface in my 'debug lindy' workspace that's hitting the 500 error," another bundled helper (`find-surface.sh`) locates the right surface by workspace name, title, or on-screen content — then the agent reads its screen, optionally sends commands, and verifies the result.

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
- `scripts/open-side-surface.sh` — decide between `new-surface --pane <adjacent>` and `new-pane --direction right`, based on current layout.
- `references/browser.md` — full embedded-browser automation reference (loaded on demand).
- `references/ssh.md` — `cmux ssh` remote workspace reference — relay daemon, browser routing, drag-drop, reconnect semantics (loaded on demand).

The main `SKILL.md` stays lean by delegating the browser and SSH subsystems to their reference docs. Agents only load those when the task actually involves them.

## Requirements

- **cmux.app** installed and running. The CLI talks to the app over a Unix socket (path reported by `cmux identify`). Without the app, the skill fails fast at load time.
- **`cmux` on PATH** — usually `/Applications/cmux.app/Contents/Resources/bin/cmux` after install.
- **`jq`** — required by the bundled scripts for JSON parsing. `brew install jq` on macOS.

## Install

```bash
amskills install using-cmux-cli
```

That drops the skill into `~/.claude/skills/using-cmux-cli/` where Claude Code picks it up automatically.
