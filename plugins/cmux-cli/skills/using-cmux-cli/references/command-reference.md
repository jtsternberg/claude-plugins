# Command Reference

Read for command discovery, environment and canonical nouns, sidebar metadata, natural-language mappings, or troubleshooting.

## Canonical nouns: `workspace` and `surface`

cmux is migrating from one top-level verb per action to **nouns with subcommands**. The legacy verbs keep working indefinitely and print a one-time deprecation hint **to stderr** (silence with `CMUX_QUIET=1`), so nothing breaks — but write the canonical form.

| Legacy verb | Canonical |
|---|---|
| `list-workspaces` | `cmux workspace list` |
| `new-workspace` | `cmux workspace create` (same flags) |
| `close-workspace` | `cmux workspace close <ws>` |
| `rename-workspace` | `cmux workspace rename <ws> --title <new>` |
| `select-workspace` | `cmux workspace select <ws>` |

`cmux workspace` also carries verbs with no legacy equivalent, worth knowing they exist:

- `workspace env [ws] [--mask]` — the workspace's configured environment variables; `--mask` redacts the values, which is what you use when the output is going anywhere the user might paste it.
- `workspace reconnect [ws]` / `workspace disconnect [ws]` — reconnect or drop a remote (SSH) workspace, **including one whose automatic reconnect gave up because the host was unreachable**. This is the answer to a dead `cmux ssh` workspace; see [references/ssh.md](ssh.md).
- `workspace status [set <lane|auto>]`, `workspace loading <on|off>`, `workspace group <…>`.

`cmux surface` is the other noun, and the skill's older `surface resume` is only one corner of it:

- `surface ls [<machine>|local] [--refresh]` — the **resource catalog**. Terminals, VNC displays and browsers on this Mac and on every cloud machine are addressed as `<machine>/<kind>/<key>`; panes merely project them.
- `surface open <resource> [--pane <p>] [--left|--right|--up|--down|--tab] [--new]` — project a resource into a pane. It **reuses the pane already showing that resource** unless `--new`, which makes it the cheap way to bring an existing thing into view rather than spawning a duplicate.
- `surface new-terminal --machine <id|local> [--cwd <dir>] [--name <name>]` — create a terminal on a machine.
- `surface resume <set|show|get|clear>` — attach restart-command metadata to a terminal surface.

There is **no** `window`, `pane`, or `tab` noun yet — those error. Keep using `list-windows`, `new-pane`, `tab-action`, etc.

## Environment variables

cmux auto-populates these in every terminal it spawns:

- `CMUX_WORKSPACE_ID` — default `--workspace` for **every** command
- `CMUX_SURFACE_ID` — default `--surface`
- `CMUX_TAB_ID` — default `--tab` for `tab-action`
- `CMUX_SOCKET_PATH` — override the socket location. **Trust `cmux identify`'s `socket_path` over any written-down default**, including this one: the CLI defaults to `~/.local/state/cmux/cmux.sock` and auto-discovers tagged/debug sockets, while `~/Library/Application Support/cmux/cmux.sock` and `/tmp/cmux.sock` both appear in circulation as the answer.
- `CMUX_SOCKET_PASSWORD` — socket auth; `--password` flag > this env var > Settings-stored password
- `CMUX_SOCKET_ENABLE` — force-enable or disable the socket entirely (`1`/`0`/`true`/`false`/`on`/`off`)
- `CMUX_QUIET` — set to `1` to silence the one-time deprecation notices the legacy verbs print (see [Canonical nouns](#canonical-nouns-workspace-and-surface)). Those notices go to **stderr**, so they never corrupt a pipe into `jq`; this is for log noise, not correctness.
- `CMUX_SOCKET_MODE` — access mode: `cmuxOnly` (default; only cmux-spawned processes connect), `allowAll` (any local process), or `off`. Also accepts `cmux-only` / `allow-all`. If you're invoking cmux from a process that wasn't spawned by cmux (CI, non-cmux shell, foreign wrapper) and getting connection refused, `CMUX_SOCKET_MODE=allowAll` is the usual fix — but understand the implication: any local process gains control of cmux.

---

## Waiting, and knowing whether something happened: use `cmux events`

**Before you write a `read-screen` loop, a `pgrep` poll, or a scheduled wake-up, check whether an event answers the question.** `cmux events` streams newline-delimited JSON for surfaces opening and closing, prompts being submitted, agent turns starting and ending, notifications and sidebar writes — and the buffer is **retained and replayable**, so it answers about the past too.

```bash
# Blocking, zero wake-ups: wait up to 10 minutes for that agent's turn to end.
cmux events --category agent --name agent.hook.Stop \
            --timeout 600 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg s "$SURF_ID" \
      'select(.payload.phase=="completed" and .surface_id==$s)' | head -1
```

Three questions events answer by fact, where the screen answers only by inference:

| Question | Event | Why it beats the screen |
|---|---|---|
| Did my message submit into that REPL? | `workspace.prompt.submitted` | Carries a 240-char `message_preview` plus a `message_length` that is the true length from cmux 0.65.0 (before that, the preview's length, capped at 240), so on 0.65.0+ a length mismatch *measures* the silent-byte-loss failure; a frame count measures fragmentation on any version. |
| Is that agent done? | `agent.hook.Stop` / `SubagentStop` / `SessionEnd` | A real turn boundary, not a spinner's elapsed-time parenthetical. |
| Does the new surface exist yet? | `surface.created` | Reports the `surface_id` and `pane_id` outright. (Existing ≠ PTY attached — the [readiness probe](opening-surfaces.md#default-principle-make-new-work-visible-to-the-user) is still required.) |

Exit code is `0` on a match and `1` on `--timeout`, with the timeout message on stderr. Scripted use is always `--no-ack --no-heartbeat 2>/dev/null` — the ack frame has no `.name` and will break a naive `jq` filter.

The full catalog (38 event names), the payload shapes, the `agent.hook.*` double-fire, and the verification recipes are in **[references/events.md](events.md)**. Read it before building anything that waits.

---

### Split the current pane

```bash
cmux new-split --help
```

`new-split` always creates a **terminal** surface. For a browser pane, use `cmux new-pane --type browser` instead — `new-split` has no `--type` flag.

### List / create workspaces, inspect the tree

```bash
cmux workspace --help
```

`workspace create` takes the same flags the legacy `new-workspace` did — `--name`, `--description`, `--cwd`, `--command`, `--layout`, `--group`, `--focus` — so `cmux workspace create --help` is the one to read when building a call.

```bash
cmux tree --help
```

`tree --all` is the one-call answer to "what exists in cmux right now?" — but note it **flattens** geometry (see the next section).

### Layouts (the geometry API)

```bash
cmux layout --help
```

`cmux layout` is the **only** way to get or reproduce full split geometry — `direction` (horizontal/vertical), the divider `split` ratio, and nesting. `tree --json` returns a flat `panes[]` list with none of those, so a left/right split and a top/bottom split are byte-identical in `tree` output. When the user needs orientation, divider position, or exact layout reproduction, use `layout`.

- `layout save <name> [--workspace <ref>] [--overwrite] [--description <text>]` — snapshot a **live** workspace into cmux's own store (persists across app/daemon restarts).
- `layout get <name>` — print the layout as a recursive binary split-tree JSON carrying complete geometry. This is the export; there is no separate `export` subcommand.
- `layout open <name> [--cwd <dir>] [--focus <true|false>]` — rebuild a saved layout as a new workspace; `--cwd` relocates every surface's working dir.
- `layout list [--json]` / `layout delete <name>`.

`cmux new-workspace --layout '<json>'` accepts the same split-tree JSON inline and rebuilds an entire split structure — seeding each surface's startup `command` — in one call:

```bash
cmux new-workspace --name Dev --layout '{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","command":"vim"}]}},{"pane":{"surfaces":[{"type":"terminal","command":"npm run start"}]}}]}'
```

The tree shape, surface fields (`type`/`cwd`/`focus`/`url`/`command`), the tree↔`tree` DFS ordering guarantee, and worked workflows all live in [references/layouts.md](layouts.md).

### Tab actions

```bash
cmux tab-action --help
```

### Wait for something to happen

```bash
cmux events --help
```

Recipes and the event catalog: [references/events.md](events.md).

### Notifications

```bash
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

```bash
cmux set-status --help
```

```bash
cmux log --help
```

Reach for these when work takes more than a few seconds and the user might look away — "Running tests (3/42)" as a progress bar is much better than nothing visible.

**Progress is not fire-and-forget.** `set-progress` and `set-status` are one-shot writes — the value sticks until you push another one. For long-running work, pair a periodic updater with a `pgrep`-based exit detector, then clear and `notify` when the process exits. See [`references/progress-loops.md`](progress-loops.md) for the worked recipe.

---

## Everything else (run `cmux <cmd> --help` on demand)

Vocabulary for less-frequent commands — just enough so you know what exists. Signatures live in `--help`.

- **Windows**: `list-windows`, `current-window`, `new-window`, `focus-window`, `close-window`, `move-workspace-to-window`
- **Workspaces** (beyond the inlined set): `select-workspace`, `close-workspace`, `rename-workspace`, `reorder-workspace`, `workspace-action`, `ssh <destination>` (full SSH subsystem: [references/ssh.md](ssh.md))
- **Panes & surfaces** (beyond `new-split`): `new-pane`, `new-surface`, `focus-pane`, `move-surface`, `reorder-surface`, `close-surface`, `list-panes`, `list-pane-surfaces`, `drag-surface-to-split`. **Use `new-pane --type browser` for browser panes — `new-split` is terminal-only.**
- **Layouts** (geometry API — the only source of split orientation/ratio/nesting): `layout save`, `layout list`, `layout get`, `layout open`, `layout delete`; `new-workspace --layout '<json>'` rebuilds a whole split tree inline. Full detail in [references/layouts.md](layouts.md).
- **Panel I/O** (surfaces ≠ panels): `send-panel --panel <ref>`, `send-key-panel --panel <ref>`
- **Notification mgmt**: `list-notifications`, `clear-notifications`
- **Embedded browser**: full subsystem in [references/browser.md](browser.md). Master index: `cmux browser --help`. Default to `browser snapshot` over `screenshot` unless producing a PNG for a human.
- **tmux-compat**: `capture-pane`, `resize-pane`, `wait-for`, `swap-pane`, `break-pane` / `join-pane`, `next-window` / `previous-window` / `last-window` / `last-pane`, `find-window`, `clear-history`, `set-buffer` / `list-buffers` / `paste-buffer`, `display-message`, `set-hook` / `bind-key` / `unbind-key` / `copy-mode`, `respawn-pane`, `pipe-pane`
- **Show the user something**: `markdown [open] <path>` (rendered markdown panel, live-reloads on disk change), `diff [--unstaged|--staged|--branch|--last-turn]` (renders a diff in a browser split; `--last-turn` is *changes since this surface's last agent-turn baseline*, i.e. a one-call "here's what I just did"), `set-buffer`/`paste-buffer`
- **Diagnose a hot or stuck cmux**: `top [--all] [--processes] [--sort cpu|mem|proc] [--format tsv]` attributes CPU/RAM to window/workspace/pane/surface/webview; `memory [--groups <n>]` separates the app's own footprint from recursive child-process RSS. This is the first move on "cmux is pegged" / "which pane is spinning", not `ps`.
- **Agent session history**: `vault sessions`, `vault search <query>` (supports `agent:`, `repo:`, `ws:`, `before:`/`after:` operators), `vault checkpoints`, `vault checkpoint --name`, `vault fork (--checkpoint|--turn) [--open]` — an index over past agent sessions, with checkpoint/fork. Overlaps the `graveyard` CLI and the `session-tools` skills; reach for whichever the user names.
- **Agent hooks**: `hooks setup [--agent <name>]`, `hooks <agent> install|uninstall` — cmux's integrations for 17 agents (codex, opencode, pi, gemini, cursor, amp, …). Claude Code's hooks are injected automatically by cmux's claude wrapper, so there is nothing to install for claude. `claude-hook <session-start|active|stop|idle|notification|prompt-submit>` still exists as the internal entrypoint.
- **Misc**: `refresh-surfaces`, `reload-config` (reloads **both** Ghostty config and `~/.config/cmux/cmux.json`, refreshing terminals in place — no app restart), `surface-health`, `trigger-flash`, `restore`/`fork` (session checkpoints), `sessions list`, `comments list`, `automation <list|show|test|enable|disable|logs|reload>`, `themes`, `right-sidebar`/`sidebar`, `feed tui|clear`, `sudo run` (Touch ID-gated privileged command), `remotes`, `popup`, `move-tab-to-new-workspace`, `reorder-workspaces`, `local-tmux`/`tmux attach`, `mosh`/`mosh-tmux`/`ssh-tmux`
- **Cloud machines**: `cmux vm` (alias `cmux cloud`) runs remote devboxes, and `cmux agent --agent <claude|codex|opencode|pi>` starts a detached coding agent on one. Large subsystem with its own live guide — read **`cmux cloud guide`** rather than guessing; nothing about it is mirrored here.
- **The user's checklist — do not touch it**: `cmux todo <add|list|check|uncheck|start|edit|rm|clear|set|open>` is the per-workspace sidebar checklist, and cmux's own help is explicit that **it belongs to the user**: don't add, edit, complete, remove or replace items on your own initiative, only when the user explicitly asks. Use your own task tracking for your plans. `cmux todo list` to read it is fine.
- **RPC escape hatch**: `cmux rpc <method> [json-params]` when no first-class subcommand exists. Skips the typed validation wrapped subcommands get — last resort.

---

## Natural-language translation

When the user describes an action informally, map it to cmux vocabulary:

**Note on `<handle>` placeholders below**: replace with a UUID resolved from `cmux identify --json --id-format both` (e.g. `.caller.surface_id`), `cmux tree --all --json --id-format both` (each node's `.id`), `find-surface.sh --json` (`.surface_id` / `.workspace_id`), or the `$CMUX_*_ID` env vars — all of which are UUIDs. The `surface:3` / `workspace:2` style refs in the examples are placeholders for readability; pass the UUID in real calls so a renumbered ref can't retarget the command. `$CMUX_SURFACE_ID` / `$CMUX_WORKSPACE_ID` are your own UUIDs and are exactly what to paste.

| User says | cmux command | Notes |
|-----------|--------------|-------|
| "open a new tab next to mine" / "new terminal side-by-side" / **any bare "open a terminal" / "start a dev server" / "run Y in a new terminal"** | [Default recipe](opening-surfaces.md#default-principle-make-new-work-visible-to-the-user) — `open-side-surface.sh --title "<purpose>" --json` + `cmux send --surface <uuid> "...\n"` | Default: the user wants to watch. Never silently spawn a new workspace. Always `--title` it, and report the title + workspace name, not the ref. |
| "ssh to X" / "ssh into box.example.com" (ambiguous) | [Default recipe](opening-surfaces.md#default-principle-make-new-work-visible-to-the-user) with `cmux send --surface <ref> "ssh user@host\n"` | Plain SSH in a visible split. Agent can `read-screen` while user watches. |
| "ssh into X **as a workspace**" / "I need drag-drop / remote browser / relay" | `cmux ssh box.example.com` | Escape hatch — opens a **new workspace** (hidden tab). Warn the user. See [references/ssh.md](ssh.md). |
| "split this right" / "split pane right" | `cmux new-split right` | Literal split — creates a new pane column (terminal only). |
| "open a new workspace in /foo" / "as its own tab" | `cmux new-workspace --name "<purpose>" --cwd /foo` | Explicit escape hatch — hidden tab, so `--name` is mandatory: it's the only way the user finds it. `--command` auto-runs something on launch. |
| "open a new cmux window" / "in a separate window" | `cmux new-window` | Escape hatch — separate OS window. |
| "what's in the other pane?" / "read the terminal" | `cmux read-screen` | add `--scrollback --lines 200` for history |
| "run `npm test` in the other pane" | `cmux send --surface <ref> "npm test\n"` | shell target: **append `\n`** or the command never runs. Into a live `claude` REPL the `\n` does *not* submit — [see the gotcha](terminal-io.md#gotcha-a-trailing-n-does-not-submit-into-a-tuiink-repl) |
| "send ctrl-c to that pane" | `cmux send-key --surface <ref> C-c` | use `send-key` for modifiers, not `send` |
| "rename this workspace to 'build'" | `cmux rename-workspace "build"` | inside cmux, current workspace is default |
| "pin this tab" / "close tabs to the right" | `cmux tab-action --action pin` / `--action close-right` | see `cmux tab-action --help` for full action list |
| "notify me when the build finishes" | `cmux notify --title "Build done" --body "…"` | call *after* the long-running command returns |
| anything involving the embedded browser (open URL, click, type, snapshot, screenshot, waits, cookies, eval, …) | see [references/browser.md](browser.md) | loaded on demand; `cmux browser --help` is the live master index |
| remote host work (SSH workspace, drag-drop to remote, running agents on remote box, browser hitting remote `localhost`) | see [references/ssh.md](ssh.md) | `cmux ssh <host>` creates the workspace; reference covers the whole subsystem |
| "list everything" (workspaces/panes/surfaces) | `cmux tree --all` | one call, full hierarchy — but flat, no split geometry |
| "save this layout" / "how is this workspace split?" / "recreate this layout in /foo" | `cmux layout save <name>` / `cmux layout get <name>` / `cmux layout open <name> --cwd /foo` | `layout` is the only API with split direction, divider ratio, and nesting. See [references/layouts.md](layouts.md). |
| "open a workspace laid out like X with these commands running" | `cmux workspace create --layout '<split-tree json>'` | rebuilds the whole split tree and seeds each surface's `command` in one call |
| "tell me when that agent / build is done" / "wait for X then …" | `cmux events --name agent.hook.Stop --timeout <s>` | One blocking call, no polling and no scheduled wake-ups. See [references/events.md](events.md). |
| "did that message actually go through?" | `cmux events --name workspace.prompt.submitted` | Exact `message_length` + preview — measures loss and fragmentation instead of guessing from the input box. |
| "show me what you changed" / "show me the diff" | `cmux diff --last-turn` (or `--unstaged` / `--staged` / `--branch`) | Renders in a browser split. `--last-turn` = since this surface's last agent-turn baseline. |
| "show me this plan / doc" | `cmux markdown open <path>` | Formatted panel, live-reloads as the file changes — better than pasting it into chat. |
| "cmux is slow" / "what's pegging my CPU?" | `cmux top --all --sort cpu` / `cmux memory` | Attributes usage to a specific surface/pane/webview. Don't reach for `ps`. |
| "find that session where we did X" | `cmux vault search "<query>"` | Indexed past agent sessions; `agent:` / `repo:` / `ws:` / `before:` / `after:` operators. |
| "my ssh workspace went dead" / "reconnect it" | `cmux workspace reconnect [<ws>]` | Works even after automatic reconnect gave up on an unreachable host. |
| "add that to my todo list" | `cmux todo add "…"` | **Only** on an explicit request — the checklist is the user's. Never write to it on your own initiative. |

## Post-mutation verification

cmux prints what it did (new surface ref, new workspace ID, applied title, etc.). **Read the output** — don't assume success from exit code alone.

- After creating anything (`new-split`, `new-pane`, `new-surface`, `new-workspace`), confirm the new ref appears in the output, then confirm with `cmux tree --workspace <ws-uuid>` that it carries the **title you gave it**. Refs are for your follow-up calls; the title + workspace name are what you tell the user ([details](opening-surfaces.md#name-it-then-report-it-by-name-required)). A report of "opened `surface:258`" is a failed report even when the command succeeded.
- After `send`, if a command was supposed to run, verify with `read-screen --scrollback --lines <n>` rather than trusting it landed — the bare form follows the user's scroll, and a `Jump to bottom` marker in a capture means the view is scrolled and stale, not that the send failed ([details](terminal-io.md#gotcha-read-screen-returns-the-scrolled-viewport-not-the-live-bottom)).
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
8. **A command printed a deprecation notice?** `list-workspaces`, `new-workspace`, `close-workspace`, `rename-workspace` and `select-workspace` are now aliases that hint at `cmux workspace <verb>` ([Canonical nouns](#canonical-nouns-workspace-and-surface)). The notice goes to **stderr** and the legacy form keeps working, so it never breaks a pipe — write the canonical form, or set `CMUX_QUIET=1` for a noisy script.
9. **`jq` choking on `cmux events` output?** Two non-event lines share those streams: the subscription **ack** frame on stdout (suppress with `--no-ack`, plus `--no-heartbeat`) and `Error: Timed out waiting for a matching event` on stderr with exit 1 (keep stderr out of the pipe with `2>/dev/null`). Neither means the stream is broken.
10. **`cmux identify --json` gave you `null` for an id?** The default payload has refs only. Pass `--id-format uuids` or `--id-format both` before concluding cmux has lost track of your surface.
11. **`Terminal surface not found` (or `Failed to read terminal text`) on a surface that exists?** Mostly historical — `open-side-surface.sh --wait-ready` handles this internally. If you hit it from a different code path: `read-screen` errors while `cmux tree` clearly shows the surface exists. The surface is real — its PTY backend just isn't attached yet, and the error wording says "doesn't exist" when it means "not attached." Common on surfaces created less than ~1 second ago.

   **A `cmux send` is what attaches the PTY** — lazily, on the first send. So waiting for `read-screen` to start working will not, on its own, get you there on a `--focus false` surface: verified on cmux 0.64.22, a surface created `--focus false` answered `Error: internal_error: Failed to read terminal text` indefinitely before its first send and read fine straight after one. Send the probe, then read.

   `cmux focus-pane --pane <pane-ref>` also attaches the backend, eagerly. **Don't use it for this.** It moves the user's focus into the surface, so whatever they are typing at that moment goes to the new shell — that is how a hotline launch command became `rkebash /tmp/…`, produced `zsh: command not found`, and burned a 60s boot budget. Measured saving over the probe send: ~0.1s.

   Don't chase this as a "stale ref" or "wrong workspace" bug — the surface is fine, the PTY just isn't ready.
