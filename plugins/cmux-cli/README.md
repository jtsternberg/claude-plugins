# cmux-cli

Claude Code plugin that teaches agents to control [cmux](https://cmux.sh) — the macOS terminal multiplexer and workspace manager — through its `cmux` CLI.

## What it does

Exposes cmux's surface area to Claude:

- **Windows / workspaces** — list, create, rename, focus, reorder, close
- **Panes / surfaces / tabs** — split, focus, move, rename, close
- **Terminal I/O** — `send` keystrokes, `read-screen`, `send-key`
- **Notifications** — post toasts into a workspace
- **Sidebar metadata** — status pills, progress bars, and log entries in the workspace sidebar (great for long-running agent work the user might look away from)
- **Layouts** — save, inspect, and reproduce full split geometry (`layout save/get/open`); rebuild a whole split tree with `new-workspace --layout '<json>'`. The layout API is the only source of split orientation, divider ratios, and nesting — `tree` flattens all of that away.
- **Browser automation** — drive cmux's embedded browser (navigate, click, type, screenshot, eval, snapshot, cookies, storage, …)
- **tmux-compat commands** — `capture-pane`, `resize-pane`, `wait-for`, `swap-pane`, and more

The skill is deliberately thin: rather than mirroring cmux's flags into prose (which would bitrot the moment cmux ships a new release), it runs `cmux <cmd> --help` inline at invocation time. The CLI itself is the source of truth.

## Codified workflows

Two common multi-step patterns are baked in as decision trees rather than left for the agent to rediscover:

1. **Open a side-by-side surface in the current window** — routes intelligently between `cmux new-surface --pane <adjacent>` (when an adjacent pane already exists, so the new surface lands as a tab there) and `cmux new-split right` (when it doesn't). Uses `cmux identify`'s `caller.pane_ref` to know where the agent is, and `focused.pane_ref` when the user means "next to what I'm looking at" rather than "next to mine". Every surface it opens gets a human-visible title (`--title`), and it hands back `surface_title` + `workspace_name` — because "opened surface:258" is a correct handle and a useless report: cmux never shows refs in its UI and they renumber as tabs come and go.
2. **Target another surface (find → read → interact)** — uses the bundled `find-surface.sh` helper to locate a surface by workspace name, title, or on-screen content, then `cmux read-screen` / `cmux send` against the returned handle.

## Skills

- **using-cmux-cli** — the core skill described above.
- **auto-rename** — generates and applies a concise, meaningful name for a tab (surface) or workspace. It summarizes what's actually running there — for claude/codex/agent sessions it reads the scrollback and names the *task* the session is doing, not the tool — then applies it via `cmux rename-tab` / `cmux rename-workspace`. Supports the caller's own tab, the focused tab, a described target, or batch-renaming all workspaces. Trigger with "rename this tab", "auto-rename", "name my workspaces", "fix these tab names".
- **send-at** — deliver a prompt into one **exact** existing cmux surface (by UUID) at a target time, from within the current agent session. The agent waits with a harness-native in-session clock (Claude: a backgrounded until-clock loop that re-invokes the same session; Codex: a blocking `functions.wait` exec cell), then a tiny bundled helper resolves the UUID from a single `cmux tree` snapshot, `send`s the text, and submits with a separate `send-key Enter` plus a basic read-screen check. It is a **same-session, best-effort timer, not a durable scheduler** — it fires only while the session and Mac stay alive, because the send must run from a process with cmux ancestry (a `launchd`/`cron` job or cloud routine can't drive cmux). Hard contract: exact surface only, no new surface, no fork, no fallback — if the UUID is gone or a send fails, it reports and stops. Trigger with "at 3pm send X to surface &lt;uuid&gt;", "in 20 minutes paste this into that tab".

## Auto-resolved context

At skill load, the plugin inlines `cmux identify --json` so the agent sees `caller.*` (where it's running), `focused.*` (where the user is looking), and the authoritative `socket_path` before its first turn. No warm-up round-trips needed.

## Installation

```
claude plugin install jtsternberg/cmux-cli
```

## Requirements

- cmux.app installed and running (the CLI talks to it over a Unix socket — authoritative path is whatever `cmux identify` reports; typically `~/Library/Application Support/cmux/cmux.sock`, but some builds use `/tmp/cmux.sock`)
- `cmux` on PATH (typically `/Applications/cmux.app/Contents/Resources/bin/cmux`)
- `jq` on PATH — required by the bundled `find-surface.sh` helper (macOS: `brew install jq`)

## Triggering

The skill activates when you mention cmux, workspaces, panes, surfaces, tabs, or ask to drive a cmux session (e.g., "split this pane right", "open a new tab next to mine", "read the terminal output from workspace 2", "send `git status` to the other pane", "find the surface in my 'debug lindy' workspace that's hitting the 500 error", "show build progress in the sidebar", "use cmux's browser to open localhost:3000").
