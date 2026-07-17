---
name: using-cmux-cli
description: "Drives cmux (macOS terminal multiplexer / workspace manager) via the `cmux` CLI — windows, workspaces, panes, surfaces, tabs, terminal I/O, the embedded browser, notifications, and sidebar progress."
when_to_use: "Use when the user mentions cmux, workspaces, panes, surfaces, tabs, or splits; asks to send keystrokes to or read output from a terminal; wants to drive cmux's embedded browser; wants to post a notification into a workspace; or runs tmux-style commands (capture-pane, wait-for, swap-pane) where cmux is the multiplexer in play."
argument-hint: "[describe what you want to do]"
allowed-tools:
  - "Bash(cmux *)"
  - "Bash(which cmux)"
  - "Bash(${CLAUDE_SKILL_DIR}/scripts/*)"
  - "Bash(jq *)"
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

**Target by UUID. Always resolve a handle to its UUID and pass that UUID to any command that acts on it.** UUIDs are permanent identities for a window/workspace/pane/surface — they name the same object for the life of that object, across every command and every session.

cmux accepts three handle formats anywhere a `window`, `workspace`, `pane`, or `surface` flag appears. Understand all three, and reach for the first:

- **UUIDs** — full identifiers, stable for the object's lifetime. **This is what you pass to commands.**
- **Short refs** — `window:1`, `workspace:2`, `pane:3`, `surface:4`. These are *positional display labels*: an index within scope that cmux reassigns as objects open and close. A ref like `surface:318` names whatever currently sits in that slot, which may be a different object a moment later. Treat refs as human-readable output to show the user, and as throwaway input only within a single read that you immediately act on — resolve to a UUID first whenever the handle outlives one command.
- **Bare indexes** — same positional, reassignable nature as short refs.

`tab-action` additionally accepts `tab:<n>` (also positional).

**Get UUIDs like this:**
- Your own location: the `CMUX_*_ID` env vars are already UUIDs (`CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_TAB_ID`), and `cmux identify --json` returns your caller/focused UUIDs.
- Anything else: `cmux tree --all --json --id-format uuids` (or `--id-format both` to see refs alongside for a human). Snapshot once, read the UUIDs you need, then target by those.

### Destructive and bulk operations: resolve UUIDs up front

For anything that mutates or removes state — `close-surface`, `close-workspace`, `close-window`, `swap-pane`, `move-surface`, or any loop over several targets — **collect every target UUID in one `tree --json --id-format uuids` snapshot first, then act by UUID.** This is the affirmative rule that keeps bulk operations correct:

1. `cmux identify --json` → note your **own** surface/pane UUID, so you can keep it out of the target set (closing the surface your agent runs in kills the agent's tty — the process goes down with the pane).
2. `cmux tree --all --json --id-format uuids` → collect the target UUIDs.
3. Exclude your own UUID from step 1.
4. Act on each **by UUID**.

Because UUIDs are permanent, acting on one never changes what the others refer to — so a close-loop stays aimed at exactly the objects you chose. (Positional refs renumber as each object closes, so a ref captured before the loop can point somewhere new mid-loop — including your own pane. UUIDs are immune to that.)

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

**Fresh surfaces need a moment before their PTY accepts input — sending immediately can drop your `\n` (the shell's "Last login" banner prints *after* your typed command, swallowing the newline, leaving the command sitting at the prompt unexecuted).** Use `--wait-ready` on `open-side-surface.sh` and the script handles both this and the "Terminal surface not found" PTY-attach race internally.

The one-call recipe:

```bash
# 1. Open a sibling surface next to the user's current view AND wait until
#    its PTY is attached + shell is actually executing input. --wait-ready
#    handles both the focus-pane attach step and a round-trip probe; on
#    timeout it exits 3 with a diagnostic instead of returning a non-ready
#    surface ref.
SID=$(${CLAUDE_SKILL_DIR}/scripts/open-side-surface.sh --wait-ready --json | jq -r '.surface_id')

# 2. Send the work into it, targeting the surface's UUID. Append \n so it runs.
cmux send --surface "$SID" "ssh user@host\n"
# or: cmux send --surface "$SID" "npm run dev\n"
# or: cmux send --surface "$SID" "cargo watch -x test\n"

# 3. Verify it actually executed — see "Send keystrokes" below for why.
cmux read-screen --surface "$SID" --lines 20
```

> **Manual fallback** (historical — most callers should use `--wait-ready`):
> if you can't use the script, poll for readiness yourself by sending an
> `echo <unique-marker>` probe and grepping `read-screen` for ≥2 hits of the
> marker (typed input + executed output). Don't rely on a `[$%#>]` prompt
> regex — it silently misses powerline / NerdFont prompts (`❯`, `➜`, custom
> glyphs) and spins to its retry ceiling. If `read-screen` errors with
> `Terminal surface not found`, run `cmux focus-pane --pane <pane-ref>` first
> to force PTY attachment.

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

#### Gotcha: Claude Code's grayed-out next-prompt suggestion looks like real input

When the surface you're reading is running **Claude Code** (the `claude` CLI in its REPL), Claude Code renders an autosuggest hint inside its input box — a slightly-grayed string showing what it predicts the user might type next. In `cmux read-screen` output that hint appears as plain text on the prompt line, **indistinguishable from text the user actually typed**.

This has burned previous agents who were watching another claude session via `read-screen`: they saw the ghost suggestion, assumed *the user* had entered that command, and started narrating phantom actions ("the user just asked you to do X, and you're now running it…") — when in reality the user had typed nothing and the inner agent was still idle.

How to tell the difference:

- **Real submitted user input** is followed by output (assistant response, tool calls, screen updates further down). The prompt is usually empty or shows the *next* incoming suggestion.
- **A ghost autosuggest** sits alone inside the input box (e.g. `╭─...─╮ / │ > update the PR description / ╰─...─╯`) with no output below it, and the cursor often sits at column 0–1 of that line, not at the end of the suggested text.

When in doubt, don't infer intent from a single `read-screen` snapshot of a claude-running surface. Re-read after a moment — real input commits and gets replaced by output; ghost text either persists unchanged or disappears as the user types something different.

Same caveat applies to other agent REPLs that render input autosuggestions (opencode, omc/omx, etc.). The pattern — text inside the input prompt with no downstream activity — is the tell, regardless of vendor.

#### Gotcha: `read-screen` returns the *scrolled* viewport, not the live bottom

`read-screen` (with or without `--scrollback --lines <n>`) captures whatever the surface is currently showing. If the **user has scrolled the surface up** (mouse wheel / trackpad in the cmux GUI), you get stale content from higher in the buffer — and `--scrollback --lines <n>` counts backward from the *scrolled* position, not the live tail, so it doesn't rescue you. The only tell in the captured text is a marker line:

```
Jump to bottom (click) ↓
```

**Real failure this caused:** an agent sent a message (`cmux send` + `send-key enter`), then `read-screen` showed no trace of it and an empty prompt, so the agent concluded the send failed and re-sent — double-queuing the message. The message *had* landed; the viewport was just scrolled up.

Second tell it missed: a line reading

```
Press up to edit queued messages
```

means messages were **queued** while the REPL was busy — i.e. your send *did* land and is waiting to be processed. Seeing it is confirmation of success, not failure.

**Detection — before concluding a send failed, grep the `read-screen` output for both markers:**

```bash
out=$(cmux read-screen --surface "$SID" --scrollback --lines 80)
printf '%s\n' "$out" | grep -qF 'Jump to bottom'            && echo "SCROLLED — view is stale, NOT a failed send"
printf '%s\n' "$out" | grep -qF 'Press up to edit queued'   && echo "QUEUED — your send landed and is waiting"
```

**Remedy.** Treat `Jump to bottom` as "I'm looking at a scrolled-up view," never as evidence the send failed — do **not** re-send. cmux has **no CLI primitive that snaps a scrolled terminal viewport to the bottom** (verified against `cmux --help`, `cmux capabilities`, and the upstream `cli-contract.md`: the only scrollback verb is `clear-history`, which *clears* history and is destructive; `browser scroll*` is for the embedded browser only, not terminals). `send-key` accepts `page_up`/`page_down`/`home`/`end` but those go to the shell/PTY, not to Ghostty's scroll region, so they won't move a GUI-scrolled viewport. What actually works:

- **Re-read after fresh output.** New output normally lands at the live bottom and pulls the viewport down with it. Wait for the REPL to emit something (or for a busy REPL to drain its queue), then `read-screen` again — the markers disappear once the view is at the live tail.
- **Corroborate with a non-viewport signal** instead of the screen text: process state (`cmux top`/`tree` shows the REPL spinning), or `wait-for` on a signal, rather than inferring from a possibly-stale capture.
- **Last resort:** the user can click the `Jump to bottom` marker in the GUI. `clear-history` would drop scrollback so future reads reflect only the live region, but it destroys history — avoid unless you own the surface.

### Send keystrokes

```!
cmux send --help
```

Escape sequences matter: `\n` and `\r` send Enter; `\t` sends Tab. If a command should actually execute, append `\n` — otherwise you're just typing into the prompt.

**Always `read-screen` after `send` to confirm execution started — not just that the send succeeded.** `cmux send` returns success when bytes are delivered to the PTY; it has no opinion about whether the remote shell did anything with them. Concrete failure mode: if you `send` into a freshly-created surface before its shell has finished initializing, the trailing `\n` gets swallowed by the shell's startup output and the command sits at the prompt unexecuted. Exit code 0, nothing happened. The only way to know is to read the screen back and look for evidence the command ran (output, new prompt line, process spinning). See the [default recipe](#default-principle-make-new-work-visible-to-the-user) for the wait-for-PTY pattern, and Troubleshooting for the `Terminal surface not found` variant. **Caveat:** the read-back only proves anything if it reflects the *live* bottom — if the user has scrolled the surface up, your capture is stale (see [read-screen returns the scrolled viewport](#gotcha-read-screen-returns-the-scrolled-viewport-not-the-live-bottom) before concluding nothing happened).

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

**Progress is not fire-and-forget.** `set-progress` and `set-status` are one-shot writes — the value sticks until you push another one. For long-running work, pair a periodic updater with a `pgrep`-based exit detector, then clear and `notify` when the process exits. See [`references/progress-loops.md`](references/progress-loops.md) for the worked recipe.

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
- `--json` — emit `{surface_ref, surface_id, pane_ref, pane_id, workspace_ref, workspace_id, mode, subject, surface_type, url, ready}` for chaining. Chain on the `*_id` UUIDs (`surface_id`, `workspace_id`), not the `*_ref` positional labels.
- `--wait-ready` — for terminal surfaces, block until the PTY is attached *and* the shell is actually executing input (forces `focus-pane`, then round-trips an `echo <marker>` probe). Without this you have to hand-roll a readiness loop and dodge the "Terminal surface not found" race. No-op for browser surfaces.
- `--wait-ready-timeout <seconds>` — override the wait-ready budget (default 5).

On success it prints the new surface's ref + pane + workspace, plus which branch it took (`new-surface` vs `new-pane`). Failure goes to stderr with exit 1 (cmux error), 2 (context error), or 3 (`--wait-ready` timed out — surface exists but PTY never echoed the probe).

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

**When the user names a surface, just pass the name as a bare query — don't reach for `read-screen` or list everything.** The script picks the strategy:

```bash
${CLAUDE_SKILL_DIR}/scripts/find-surface.sh "✳ hotline: claude-plugins → Automating (quick_call)" --json
```

A bare query (no flag) matches by **title first** — one `cmux tree` call, no screen reads — and only falls back to a content scan if the title pass is dry. Paste the tab label **verbatim**: leading status glyphs (`✳`, spinners) and surrounding whitespace are stripped from both sides before comparing, so the match holds even if the glyph has since changed. A unique hit is your answer; act on it immediately.

Reach for an explicit flag only when the bare query isn't the right shape:
- **`-w <name>`** — user pointed at a *workspace* ("in my 'debug lindy' workspace"); narrows before searching.
- **`-c <text>`** — user described *on-screen text*, not a title ("the tab hitting the 500 error"). This is the only mode that reads screens per candidate (the slow path) — scope it with `-w` when you can.
- **`-t <title>`** — same title-matching as the bare query, when you want to force title-only with no content fallback.

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
- `--json` — machine-readable output (array of `{workspace_ref, workspace_id, workspace_name, surface_ref, surface_id, surface_type, surface_title, tty, pane_ref, pane_id, window_ref, window_id, matched_on, snippet}`). Target by the `*_id` UUIDs.
- `--include-self` — by default the calling surface is excluded from results (so the agent doesn't match its own transcript when searching for text). Pass this flag if the user actually wants to see the calling surface.

Pipe `--json` through `jq` for any further filtering — e.g. `find-surface.sh -w cmux --json | jq -r '.[] | select(.surface_type=="terminal") | .surface_id'` (select the UUID to act on).

When the user describes on-screen behavior *and* a location — "find the surface in my 'debug lindy' workspace that's hitting the 500 error" — combine `-w` (cheap narrowing) with `-c` (the read-screen scan) so you only read screens inside that one workspace. But if the user just names a title, `-t` alone is enough — don't add a content scan it doesn't need (see the flag-picking rule at the top of this step).

Under the hood, the script uses `cmux tree --all --json` for discovery. If you need more fields than the script exposes (panes, selected/focused flags, index ordering), call `cmux tree --all --json | jq ...` directly.

### Step 2 — Read it

Grab the target's UUIDs from the finder's JSON and target by those:

```bash
match=$(${CLAUDE_SKILL_DIR}/scripts/find-surface.sh -w cmux -c "500 error" --json | jq -r '.[0]')
WS_ID=$(jq -r '.workspace_id' <<<"$match")
SURF_ID=$(jq -r '.surface_id' <<<"$match")

cmux read-screen --workspace "$WS_ID" --surface "$SURF_ID" --scrollback --lines 500
```

**Both `--workspace` and `--surface` must be passed explicitly** when targeting somewhere other than your own surface — the `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` defaults point at *your* location, not the target. Use the `*_id` UUIDs (not `*_ref`): the target may open or close sibling surfaces between your calls, which renumbers refs but never touches UUIDs.

### Step 3 — Interact (optional)

To type into the target (same UUIDs):

```bash
cmux send --workspace "$WS_ID" --surface "$SURF_ID" "command here\n"
cmux send-key --workspace "$WS_ID" --surface "$SURF_ID" C-c
```

Append `\n` on `send` if the command should actually execute. Use `send-key` for modifiers, arrows, ctrl-combos.

### Step 4 — Verify

After sending, re-read with `cmux read-screen --surface "$SURF_ID" --scrollback --lines 50` to confirm the effect landed. Don't trust exit codes — cmux's `send` succeeds whether or not the remote process did anything useful with the input. If the re-read shows a `Jump to bottom` / `Press up to edit queued messages` marker, the view is scrolled and your capture is stale — don't read that as a failed send ([details](#gotcha-read-screen-returns-the-scrolled-viewport-not-the-live-bottom)).

### Gotcha: which workspace does a given surface live in?

`find-surface.sh` already pairs each surface with its workspace — use the `workspace_id` it returns as the `--workspace` value for the follow-up `read-screen`/`send`. Hand-parsing `cmux list-pane-surfaces` loses this pairing; prefer the script.

---

## Everything else (run `cmux <cmd> --help` on demand)

Vocabulary for less-frequent commands — just enough so you know what exists. Signatures live in `--help`.

- **Windows**: `list-windows`, `current-window`, `new-window`, `focus-window`, `close-window`, `move-workspace-to-window`
- **Workspaces** (beyond the inlined set): `select-workspace`, `close-workspace`, `rename-workspace`, `reorder-workspace`, `workspace-action`, `ssh <destination>` (full SSH subsystem: [references/ssh.md](references/ssh.md))
- **Panes & surfaces** (beyond `new-split`): `new-pane`, `new-surface`, `focus-pane`, `move-surface`, `reorder-surface`, `close-surface`, `list-panes`, `list-pane-surfaces`, `drag-surface-to-split`. **Use `new-pane --type browser` for browser panes — `new-split` is terminal-only.**
- **Panel I/O** (surfaces ≠ panels): `send-panel --panel <ref>`, `send-key-panel --panel <ref>`
- **Notification mgmt**: `list-notifications`, `clear-notifications`
- **Embedded browser**: full subsystem in [references/browser.md](references/browser.md). Master index: `cmux browser --help`. Default to `browser snapshot` over `screenshot` unless producing a PNG for a human.
- **tmux-compat**: `capture-pane`, `resize-pane`, `wait-for`, `swap-pane`, `break-pane` / `join-pane`, `next-window` / `previous-window` / `last-window` / `last-pane`, `find-window`, `clear-history`, `set-buffer` / `list-buffers` / `paste-buffer`, `display-message`, `set-hook` / `bind-key` / `unbind-key` / `copy-mode`, `respawn-pane`, `pipe-pane`
- **Misc**: `markdown [open] <path>`, `refresh-surfaces`, `reload-config`, `surface-health`, `trigger-flash`, `claude-hook <session-start|stop|notification>`
- **RPC escape hatch**: `cmux rpc <method> [json-params]` when no first-class subcommand exists. Skips the typed validation wrapped subcommands get — last resort.

---

## Natural-language translation

When the user describes an action informally, map it to cmux vocabulary:

**Note on `<handle>` placeholders below**: replace with a UUID resolved from `cmux identify --json --id-format both` (e.g. `.caller.surface_id`), `cmux tree --all --json --id-format both` (each node's `.id`), `find-surface.sh --json` (`.surface_id` / `.workspace_id`), or the `$CMUX_*_ID` env vars — all of which are UUIDs. The `surface:3` / `workspace:2` style refs in the examples are placeholders for readability; pass the UUID in real calls so a renumbered ref can't retarget the command. `$CMUX_SURFACE_ID` / `$CMUX_WORKSPACE_ID` are your own UUIDs and are exactly what to paste.

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
- After `send`, if a command was supposed to run, verify with `read-screen` rather than trusting it landed — but a `Jump to bottom` marker in the output means the view is scrolled and stale, not that the send failed ([details](#gotcha-read-screen-returns-the-scrolled-viewport-not-the-live-bottom)).
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
8. **`Terminal surface not found` on a surface that exists?** Mostly historical — `open-side-surface.sh --wait-ready` handles this internally. If you hit it from a different code path: `cmux read-screen --surface surface:N` returns `Error: internal_error: ERROR: Terminal surface not found` but `cmux tree` clearly shows `surface:N` exists. The surface is real — its PTY backend just isn't attached yet. Common on surfaces created less than ~1 second ago. The error wording is misleading: it says "doesn't exist" but means "not attached." Two fixes:
   - **Wait + retry** — poll `read-screen` with a short sleep; the backend usually attaches within 1–2s.
   - **Force attachment** — `cmux focus-pane --pane <pane-ref>` on the surface's pane wakes the backend immediately. Useful when you can't afford to wait.
   Don't chase this as a "stale ref" or "wrong workspace" bug — the surface is fine, the PTY just isn't ready.
