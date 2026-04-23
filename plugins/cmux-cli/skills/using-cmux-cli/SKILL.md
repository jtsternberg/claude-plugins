---
name: using-cmux-cli
description: Controls cmux (macOS terminal multiplexer / workspace manager) via the `cmux` CLI. Use when the user mentions cmux, workspaces, panes, surfaces, tabs, or splits; asks to send keystrokes to / read output from a terminal; wants to drive cmux's embedded browser; or wants to post a notification into a workspace. Also triggers on tmux-style commands (capture-pane, wait-for, swap-pane) when cmux is in play.
argument-hint: [list|send|read|split|focus|notify|browser] [natural language description]
allowed-tools: Bash(cmux *), Bash(which cmux), Bash(${CLAUDE_SKILL_DIR}/scripts/*)
---

# cmux CLI

Drive cmux (`cmux`) from the command line: windows, workspaces, panes, surfaces, tabs, terminal I/O, notifications, and the embedded browser. The CLI talks to the running cmux.app over a Unix socket.

This skill only applies when the user is working with **cmux specifically** — not generic terminal multiplexers like tmux or screen.

## The golden rule: let `--help` be the source of truth

cmux ships frequently and its flags evolve. Rather than mirroring option lists into this skill (which bitrots), **run `cmux <cmd> --help` before constructing any real invocation**. The top-level overview below is inlined live; for everything else, call `cmux <cmd> --help` on demand. That single rule replaces a dozen "remember to pass --foo" footnotes.

## Current environment (resolved at skill load)

```!
cmux identify --json 2>/dev/null || echo '{"error":"cmux identify failed — see Troubleshooting"}'
```

`identify` returns three things:

- `caller.*` — your own surface/workspace/window/pane refs (where the agent is running). Use these as defaults when the user says "here" / "this pane".
- `focused.*` — where the **user** is currently looking. Often *different* from `caller`. When the user says "do that in the other tab I'm looking at", target `focused` explicitly.
- `socket_path` — the actual socket the CLI is talking to.

If `identify` fails, you're either outside cmux or the socket is unreachable — see Troubleshooting. When outside cmux, every targeted command needs explicit handles; discover them with `cmux tree --all --json`.

## Is cmux actually running?

```!
cmux ping
```

Silent success means yes. An error means the app isn't running, the socket path is wrong, or auth is misconfigured. See Troubleshooting.

## Overview: every subcommand at a glance

```!
cmux --help
```

This is the master index. Every subcommand appears here with its full signature — enough to construct most invocations on sight. For anything non-obvious, drill in with `cmux <cmd> --help`.

Capabilities of the *running* build (what flags the current app actually supports):

```!
cmux capabilities
```

## Handle conventions (read before passing IDs)

cmux accepts three handle formats anywhere a `window`, `workspace`, `pane`, or `surface` flag appears:

- **UUIDs** — full identifiers, stable across sessions
- **Short refs** — `window:1`, `workspace:2`, `pane:3`, `surface:4` (index within scope)
- **Bare indexes** — where accepted; prefer short refs for clarity

`tab-action` additionally accepts `tab:<n>`.

Output defaults to refs. Pass `--id-format uuids` or `--id-format both` when you need stable IDs (e.g., saving a handle for a later session).

### `--json` is per-command, not global

The official API docs list `--json` under "CLI options" as if it were global. In the installed build it isn't: `cmux tree --all --json` and `cmux identify --json` return structured JSON; `cmux list-workspaces --json` silently ignores the flag and prints text. When you need JSON, prefer `tree` (hierarchy) or `identify` (current context) and filter with `jq`. Run `<cmd> --json` as a quick sniff test — if the output looks like text, it's not supported there.

## Environment variables

cmux auto-populates these in every terminal it spawns:

- `CMUX_WORKSPACE_ID` — default `--workspace` for **every** command
- `CMUX_SURFACE_ID` — default `--surface`
- `CMUX_TAB_ID` — default `--tab` for `tab-action`
- `CMUX_SOCKET_PATH` — override the socket location (default: `~/Library/Application Support/cmux/cmux.sock`; the official docs also mention `/tmp/cmux.sock` on some builds — trust whatever `cmux identify` reports)
- `CMUX_SOCKET_PASSWORD` — socket auth; `--password` flag > this env var > Settings-stored password
- `CMUX_SOCKET_ENABLE` — force-enable or disable the socket entirely (`1`/`0`/`true`/`false`/`on`/`off`)
- `CMUX_SOCKET_MODE` — access mode: `cmuxOnly` (default; only cmux-spawned processes connect), `allowAll` (any local process), or `off`. Also accepts `cmux-only` / `allow-all`. If you're invoking cmux from a process that wasn't spawned by cmux (CI, non-cmux shell, foreign wrapper) and getting connection refused, `CMUX_SOCKET_MODE=allowAll` is the usual fix — but understand the implication: any local process gains control of cmux.

---

## Reference material (load on demand)

Two subsystems live in separate files to keep this skill lean. Read them only when a task actually involves them:

- [references/browser.md](references/browser.md) — embedded browser automation (navigate, click, type, snapshot/screenshot, cookies, storage, eval, waits, locators).
- [references/ssh.md](references/ssh.md) — `cmux ssh` remote workspaces (browser traffic routing, drag-drop upload, remote agents, reconnect, daemon troubleshooting).

---

## Default principle: make new work visible to the user

**When the user asks you to open anything — an ssh session, a new terminal, a dev server, a browser — they almost always want to _see_ it alongside what they're already looking at.** They're sitting in their cmux window watching you work. If you open the new thing in a separate workspace tab or a new OS window, they have to stop watching to go find it — and at that point, they might as well have done the work themselves.

### The default routing

For any "open X" / "start X" / "ssh to X" / "run Y in a new terminal" request that *doesn't* specify a destination, route through the side-by-side workflow below. Don't reach for `cmux new-workspace`, `cmux new-window`, or bare `cmux ssh <host>` — those spawn in places the user can't see without switching context.

The one-call recipe:

```bash
# 1. Open a sibling surface next to the user's current view.
REF=$(${CLAUDE_SKILL_DIR}/scripts/open-side-surface.sh --json | jq -r '.surface_ref')

# 2. Send the work into it. Append \n so the command actually runs.
cmux send --surface "$REF" "ssh user@host\n"
# or: cmux send --surface "$REF" "npm run dev\n"
# or: cmux send --surface "$REF" "cargo watch -x test\n"
```

Use `--focused` on `open-side-surface.sh` when the user says "next to the tab I'm looking at" instead of "next to yours" — the defaults diverge when the user is viewing a different tab than the one the agent lives in.

### When to break the default (escape hatches)

Flip to a separate-workspace path **only** when the user explicitly asks for it. Trigger phrases:

- "in a new workspace" / "as its own tab" → `cmux new-workspace --name "..." [--cwd <path>] [--command "..."]`
- "in a separate window" / "open a new cmux window" → `cmux new-window`
- "open a full cmux ssh workspace to X" / "I need drag-drop / remote browser / relay for agent X" → `cmux ssh <host>` (see [references/ssh.md](references/ssh.md))

When you pick a hidden path deliberately, **tell the user the new surface isn't visible yet** and how to reach it (tab switch, window focus). Surprise hiding is the failure mode this section exists to prevent.

### The `cmux ssh` decision

`cmux ssh <host>` does a lot — relay daemon, browser routing through the remote's network, drag-drop uploads via `scp`, remote `cmux` calls relayed to your local sidebar — but it **always creates a new workspace**, so the session is behind a tab the user has to switch to. Two paths:

| User's intent | Right tool | Why |
|---------------|-----------|-----|
| "ssh to host X to check a log / run a command / poke around" | side-by-side + plain `ssh` (default recipe above) | Visible immediately; plain SSH is enough for read/send/observe. |
| "ssh to host X and run a coding agent" / "I need to drag files to the remote" / "I want the browser to hit the remote's localhost" | `cmux ssh <host>` (+ warn user it opens in a new workspace) | Needs the relay daemon and workspace integration. Worth the tab-switch cost. |

If the user's request is ambiguous ("ssh into host X"), default to the visible side-by-side path. Plain `ssh` in a split gives you everything you need to read output and send commands, and the user can actually see it happen.

---

## High-frequency subcommands (inlined `--help`)

These are the commands you'll reach for constantly. Live help is pinned below so you can construct correct calls without a second round-trip.

### Read the screen

```!
cmux read-screen --help
```

Use `--scrollback --lines <n>` to grab history. Without them you only get the visible viewport — often omitting the command output you actually care about.

### Send keystrokes

```!
cmux send --help
```

Escape sequences matter: `\n` and `\r` send Enter; `\t` sends Tab. If a command should actually execute, append `\n` — otherwise you're just typing into the prompt.

### Send a single key (modifiers, arrows, ctrl-combos)

```!
cmux send-key --help
```

Use `send-key` for `C-c`, `Up`, `Enter`, etc. Use `send` for literal text.

### Split the current pane

```!
cmux new-split --help
```

`new-split` always creates a **terminal** surface. For a browser pane, use `cmux new-pane --type browser` instead — `new-split` has no `--type` flag.

### List / create workspaces, inspect the tree

```!
cmux list-workspaces --help
```

```!
cmux new-workspace --help
```

```!
cmux tree --help
```

`tree --all` is the one-call answer to "what exists in cmux right now?"

### Tab actions

```!
cmux tab-action --help
```

### Notifications

```!
cmux notify --help
```

### Sidebar metadata (show progress to the human)

**`cmux notify` vs sidebar**: use `notify` for one-shot events the user can afford to miss ("build done", "error in test 42"). Use sidebar metadata for ongoing state the user might glance at while you're working ("Running tests (3/42)", progress bars). Notifications are ephemeral; sidebar entries persist until cleared.

For long-running agent work, push status to the workspace sidebar instead of spamming the terminal. Four building blocks:

- `cmux set-status <key> <value> [--icon <name>] [--color <#hex>]` — a pill in the sidebar tab row. Use a **unique key** per tool (e.g. `claude_code`, `build`, `deploy`) so multiple tools can coexist without clobbering each other.
- `cmux set-progress <0.0–1.0> [--label <text>]` — a progress bar.
- `cmux log [--level info|progress|success|warning|error] [--source <tag>] -- <message>` — appends to the sidebar log.
- `cmux sidebar-state [--workspace <ref>]` — dump everything (cwd, git branch, ports, status pills, progress, logs) for debugging.

Clear with `clear-status <key>` / `clear-progress` / `clear-log`. List with `list-status` / `list-log --limit <n>`.

```!
cmux set-status --help
```

```!
cmux log --help
```

Reach for these when work takes more than a few seconds and the user might look away — "Running tests (3/42)" as a progress bar is much better than nothing visible.

---

## Workflow: open a side-by-side surface in the current window

This is the mechanics behind the [default visibility principle](#default-principle-make-new-work-visible-to-the-user) above. Use it for any "open / start / ssh / run" request that doesn't explicitly ask for a separate workspace. The bundled helper handles the decision tree (split vs. add-to-adjacent-pane) so you don't have to hand-roll it:

```bash
${CLAUDE_SKILL_DIR}/scripts/open-side-surface.sh [OPTIONS]
```

Requires `jq` (macOS: `brew install jq`). The script fails fast with a clear message if missing.

Key options (run `--help` for the full list):

- `--caller` (default) — open next to the agent's own pane. Use when the user says *"next to mine"*.
- `--focused` — open next to the pane the **user** is currently looking at. Use when the user says *"next to what I'm looking at"*. `caller` and `focused` usually coincide but diverge when the user is viewing a different tab than the one the agent lives in.
- `--type terminal|browser` (default terminal).
- `--url <url>` — for browser surfaces.
- `--json` — emit `{surface_ref, pane_ref, workspace_ref, mode, subject, surface_type, url}` for chaining.

On success it prints the new surface's ref + pane + workspace, plus which branch it took (`new-surface` vs `new-pane`). Failure goes to stderr with exit 1 (cmux error) or 2 (context error).

### What it decides under the hood

Keep this as a mental model — you can still hand-roll a variant when the user's request is non-standard (e.g., split left instead of right).

1. Read the subject's `pane_ref` + `workspace_ref` from `cmux identify --json`.
2. Enumerate panes in that workspace (via `cmux tree --all --json`, sorted by index).
3. Branch:
   - **Only one pane** → `cmux new-pane --direction right --type <t> [--url <u>] --workspace <ws>`. (Uses `new-pane` rather than `new-split` because only `new-pane` supports `--type browser`.)
   - **Multiple panes** → pick your-pane-index **+ 1** (fall back to **− 1** if you're rightmost), then `cmux new-surface --pane <adjacent> --type <t> [--url <u>]`. The new surface becomes a tab in that existing pane column and auto-selects.

### Why not always `new-split` / `new-pane`?

Creating a new pane column when an adjacent one already exists shoves your surface into a third column and shrinks everything. Adding a surface to an existing adjacent pane reuses the real estate the user has already allocated.

### Caveat: mixed horizontal/vertical layouts

`tree`'s pane index order tracks visual left-to-right for horizontal splits. For workspaces with mixed horizontal + vertical splits the ordering may not match visual adjacency cleanly. If the user's layout looks non-trivial, verify with `cmux tree --workspace $CMUX_WORKSPACE_ID` after the call. If you specifically need a fresh pane column instead of a tab inside an existing pane, bypass the script and call `cmux new-pane --direction right --type <terminal|browser>` directly — the script's branching is pane-count-only and won't force a new column when other panes exist.

### Verify

The script parses cmux's `OK surface:<n> pane:<p> workspace:<w>` output and reports the result. Re-confirm with `cmux tree --workspace $CMUX_WORKSPACE_ID` if you need to see it in situ — the new ref should appear under the expected pane with `[selected]` on it.

---

## Workflow: targeting another surface (find → read → send)

One of the most common agent tasks: the user says *"read what's happening in the other tab"* or *"that workspace over there — send it this command."* You're running inside one surface (your own `CMUX_SURFACE_ID`) and need to act on a different one. The mechanics:

### Step 1 — Find the surface

Use the bundled helper rather than hand-parsing `cmux tree --all`:

```bash
${CLAUDE_SKILL_DIR}/scripts/find-surface.sh [OPTIONS]
```

Requires `jq` (macOS: `brew install jq`). The script fails fast with a clear message if missing.

Key options (run `--help` for the full list):

- `-w, --workspace <name|ref>` — narrow by workspace. Fuzzy substring on the workspace **name** (e.g., `-w cmux` matches "cmux-cli skill"), or exact ref like `workspace:9`.
- `-c, --content <pattern>` — match surfaces whose on-screen text contains the pattern. Case-insensitive substring by default, `-r` for regex.
- `-t, --title <pattern>` — match by surface title (the thing shown on the tab).
- `-s, --scrollback` / `-l <n>` — include scrollback history, not just the visible viewport.
- `--json` — machine-readable output (array of `{workspace_ref, workspace_name, surface_ref, surface_type, surface_title, tty, pane_ref, window_ref, matched_on, snippet}`).
- `--include-self` — by default the calling surface is excluded from results (so the agent doesn't match its own transcript when searching for text). Pass this flag if the user actually wants to see the calling surface.

Pipe `--json` through `jq` for any further filtering — e.g. `find-surface.sh -w cmux --json | jq -r '.[] | select(.surface_type=="terminal") | .surface_ref'`.

The user often tells you the workspace by name — "find the surface in my 'debug lindy' workspace that's hitting the 500 error" — so lean on `-w` for the cheapest narrowing, then `-c` / `-t` inside it.

Under the hood, the script uses `cmux tree --all --json` for discovery. If you need more fields than the script exposes (panes, selected/focused flags, index ordering), call `cmux tree --all --json | jq ...` directly.

### Step 2 — Read it

Once you have a `surface:<n>` handle:

```bash
cmux read-screen --workspace <ws-ref> --surface <surface-ref> --scrollback --lines 500
```

**Both `--workspace` and `--surface` must be passed explicitly** when targeting somewhere other than your own surface — the `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` defaults point at *your* location, not the target.

### Step 3 — Interact (optional)

To type into the target:

```bash
cmux send --workspace <ws-ref> --surface <surface-ref> "command here\n"
cmux send-key --workspace <ws-ref> --surface <surface-ref> C-c
```

Append `\n` on `send` if the command should actually execute. Use `send-key` for modifiers, arrows, ctrl-combos.

### Step 4 — Verify

After sending, re-read with `cmux read-screen --surface <ref> --scrollback --lines 50` to confirm the effect landed. Don't trust exit codes — cmux's `send` succeeds whether or not the remote process did anything useful with the input.

### Gotcha: which workspace does a given surface live in?

`find-surface.sh` already pairs each surface with its workspace ref — that's why the next `read-screen` call has the right `--workspace` value. Hand-parsing `cmux list-pane-surfaces` loses this pairing; prefer the script.

---

## Everything else (run `--help` on demand)

For any command below, run `cmux <cmd> --help` before constructing an invocation. The one-liner is just enough context to pick the right command.

### Windows

- `cmux list-windows` — enumerate windows
- `cmux current-window` — print the focused window
- `cmux new-window` — open a new window
- `cmux focus-window --window <ref>` — focus a window
- `cmux close-window --window <ref>` — close a window
- `cmux move-workspace-to-window --workspace <ref> --window <ref>` — relocate a workspace

### Workspaces (beyond the inlined set)

- `cmux select-workspace --workspace <ref>` — focus a workspace
- `cmux close-workspace --workspace <ref>` — close a workspace
- `cmux rename-workspace [--workspace <ref>] <title>` — rename
- `cmux reorder-workspace --workspace <ref> (--index <n>|--before <ref>|--after <ref>)` — reorder tabs
- `cmux workspace-action --action <name> [--workspace <ref>]` — title/color/description actions
- `cmux ssh <destination>` — open a remote SSH workspace (browser routing, drag-drop, session persistence, remote agents). Details in [references/ssh.md](references/ssh.md).

### Panes & surfaces (beyond `new-split`)

- `cmux new-pane [--type terminal|browser] [--direction <dir>]` — create a new pane with type control. **Use this instead of `new-split` when you need a browser pane** (`new-split` only makes terminals).
- `cmux new-surface --type <terminal|browser> [--pane <ref>]` — add a surface to a pane
- `cmux focus-pane --pane <ref>` — focus a pane
- `cmux move-surface --surface <ref> [--pane <ref>] [--window <ref>]` — relocate a surface
- `cmux reorder-surface --surface <ref> (--index <n>|--before <ref>|--after <ref>)` — reorder within a pane
- `cmux close-surface [--surface <ref>]` — close a surface
- `cmux list-panes [--workspace <ref>]` — enumerate panes
- `cmux list-pane-surfaces [--workspace <ref>] [--pane <ref>]` — panes with surfaces
- `cmux drag-surface-to-split --surface <ref> <left|right|up|down>` — convert into a split

### I/O targeted at panels (not surfaces)

- `cmux send-panel --panel <ref> <text>` — text to a specific panel
- `cmux send-key-panel --panel <ref> <key>` — key to a specific panel

### Notifications (management)

- `cmux list-notifications` — see queued notifications
- `cmux clear-notifications` — clear them

### Embedded browser

Browser-specific subcommands (navigate, click, type, snapshot, screenshot, cookies, storage, eval, waits, etc.) live in [references/browser.md](references/browser.md). Load that file when a task actually involves the browser — the master index is `cmux browser --help`, and `cmux browser snapshot` is your default way to "see" a page (use `screenshot` only when producing a PNG for a human).

### tmux-compat layer

If the user's request reads like a tmux recipe, cmux exposes:

- `cmux capture-pane [--scrollback] [--lines <n>]` — tmux's capture-pane
- `cmux resize-pane --pane <ref> (-L|-R|-U|-D) [--amount <n>]` — resize
- `cmux wait-for [-S|--signal] <name> [--timeout <seconds>]` — block until signaled
- `cmux swap-pane --pane <ref> --target-pane <ref>` — swap two panes
- `cmux break-pane` / `cmux join-pane` — detach / merge panes
- `cmux next-window` / `cmux previous-window` / `cmux last-window` / `cmux last-pane` — navigation
- `cmux find-window [--content] [--select] <query>` — search
- `cmux clear-history` — clear scrollback
- `cmux set-buffer <text>` / `cmux list-buffers` / `cmux paste-buffer` — buffers
- `cmux display-message [-p] <text>` — status-bar message
- `cmux set-hook <event> <command>` / `cmux bind-key` / `cmux unbind-key` / `cmux copy-mode` — hooks & bindings
- `cmux respawn-pane` / `cmux pipe-pane` — process management

### Misc

- `cmux markdown [open] <path>` — open a markdown file in the formatted viewer
- `cmux refresh-surfaces` — force a redraw
- `cmux reload-config` — reload cmux's config without restarting
- `cmux surface-health [--workspace <ref>]` — diagnostic
- `cmux trigger-flash` — visual flash (debugging / notifications)
- `cmux claude-hook <session-start|stop|notification>` — hook integration points

### RPC escape hatch

```
cmux rpc <method> [json-params]
```

Use only when no first-class subcommand exists. Raw method call — skips the typed validation the wrapped subcommands get. Run `cmux rpc --help` for the invocation format.

---

## Natural-language translation

When the user describes an action informally, map it to cmux vocabulary:

**Note on `<ref>` placeholders below**: replace with a real handle from the `identify` block above (e.g., `caller.surface_ref`), `cmux tree`, or `find-surface.sh` output. These look like `surface:3` / `workspace:2` / `pane:1`. **Don't paste `$CMUX_*` env vars verbatim** — those are UUIDs, and while most commands accept them, mixing UUIDs and refs in troubleshooting output makes it harder to read what's what.

| User says | cmux command | Notes |
|-----------|--------------|-------|
| "open a new tab next to mine" / "new terminal side-by-side" / **any bare "open a terminal" / "start a dev server" / "run Y in a new terminal"** | [Default recipe](#default-principle-make-new-work-visible-to-the-user) — `open-side-surface.sh --json` + `cmux send --surface <ref> "...\n"` | Default: the user wants to watch. Never silently spawn a new workspace. |
| "ssh to X" / "ssh into box.example.com" (ambiguous) | [Default recipe](#default-principle-make-new-work-visible-to-the-user) with `cmux send --surface <ref> "ssh user@host\n"` | Plain SSH in a visible split. Agent can `read-screen` while user watches. |
| "ssh into X **as a workspace**" / "I need drag-drop / remote browser / relay" | `cmux ssh box.example.com` | Escape hatch — opens a **new workspace** (hidden tab). Warn the user. See [references/ssh.md](references/ssh.md). |
| "split this right" / "split pane right" | `cmux new-split right` | Literal split — creates a new pane column (terminal only). |
| "open a new workspace in /foo" / "as its own tab" | `cmux new-workspace --cwd /foo` | Explicit escape hatch — hidden tab. `--command` auto-runs something on launch. |
| "open a new cmux window" / "in a separate window" | `cmux new-window` | Escape hatch — separate OS window. |
| "what's in the other pane?" / "read the terminal" | `cmux read-screen` | add `--scrollback --lines 200` for history |
| "run `npm test` in the other pane" | `cmux send --surface <ref> "npm test\n"` | **append `\n`** or the command never runs |
| "send ctrl-c to that pane" | `cmux send-key --surface <ref> C-c` | use `send-key` for modifiers, not `send` |
| "rename this workspace to 'build'" | `cmux rename-workspace "build"` | inside cmux, current workspace is default |
| "pin this tab" / "close tabs to the right" | `cmux tab-action --action pin` / `--action close-right` | see `cmux tab-action --help` for full action list |
| "notify me when the build finishes" | `cmux notify --title "Build done" --body "…"` | call *after* the long-running command returns |
| anything involving the embedded browser (open URL, click, type, snapshot, screenshot, waits, cookies, eval, …) | see [references/browser.md](references/browser.md) | loaded on demand; `cmux browser --help` is the live master index |
| remote host work (SSH workspace, drag-drop to remote, running agents on remote box, browser hitting remote `localhost`) | see [references/ssh.md](references/ssh.md) | `cmux ssh <host>` creates the workspace; reference covers the whole subsystem |
| "list everything" (workspaces/panes/surfaces) | `cmux tree --all` | one call, full hierarchy |

## Post-mutation verification

cmux prints what it did (new surface ref, new workspace ID, applied title, etc.). **Read the output** — don't assume success from exit code alone.

- After `new-split`, confirm the new surface ref appears in the output.
- After `send`, if a command was supposed to run, verify with `read-screen` rather than trusting it landed.
- After `workspace-action` or `tab-action`, re-list (`list-workspaces` / `tree`) to confirm state.
- If output is quieter than expected, append `--id-format both` to force UUIDs + refs so there's something concrete to verify against.

## Troubleshooting

If commands fail, work through these in order:

1. **Is cmux running?** `cmux ping` — silent success means yes. Anything else, the socket can't be reached.
2. **Is the CLI on PATH?** `which cmux` → typically `/Applications/cmux.app/Contents/Resources/bin/cmux`. If missing, cmux isn't installed or the bin wasn't symlinked.
3. **Socket path override?** If `CMUX_SOCKET_PATH` is set, confirm it points at the real socket. Unset it to fall back to discovery.
4. **Auth failure?** If commands return a permission error, the socket password is wrong. `--password` > `CMUX_SOCKET_PASSWORD` env var > Settings-stored password.
5. **Version mismatch?** `cmux version` + `cmux capabilities` — if a flag the skill surfaces isn't there, the running app is older than the CLI (or vice versa).
6. **Unknown subcommand?** `cmux --help` lists everything the current build understands. If it's not there, the build predates it — consider `cmux rpc <method>` as a last resort. (The [official API docs](https://cmux.com/docs/api) list some commands like `list-surfaces` that don't exist on every build; trust `cmux --help` over the docs when they disagree.)
7. **Socket disabled / wrong mode?** `CMUX_SOCKET_ENABLE=1` to force-enable; `CMUX_SOCKET_MODE=allowAll` if you're calling cmux from a process it didn't spawn (CI runner, foreign wrapper). Default mode is `cmuxOnly`, which rejects non-cmux ancestry.
