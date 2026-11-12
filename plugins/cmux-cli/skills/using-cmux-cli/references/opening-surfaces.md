# Opening Surfaces

Read before creating a surface, choosing caller/focused placement, or marking an existing target for the user.

## Default principle: make new work visible to the user

**When the user asks you to open anything — an ssh session, a new terminal, a dev server, a browser — they almost always want to _see_ it alongside what they're already looking at.** They're sitting in their cmux window watching you work. If you open the new thing in a separate workspace tab or a new OS window, they have to stop watching to go find it — and at that point, they might as well have done the work themselves.

### The default routing

For any "open X" / "start X" / "ssh to X" / "run Y in a new terminal" request that *doesn't* specify a destination, route through the side-by-side workflow below. Don't reach for `cmux new-workspace`, `cmux new-window`, or bare `cmux ssh <host>` — those spawn in places the user can't see without switching context.

The `--wait-ready` budget covers the readiness probes after creation and naming; preflight, creation, and naming are outside it. On timeout, cleanup gets a separate two-second command budget; Hotline may make one separately bounded retry.

**Fresh surfaces need a moment before their PTY accepts input — sending immediately can drop your `\n` (the shell's "Last login" banner prints *after* your typed command, swallowing the newline, leaving the command sitting at the prompt unexecuted).** Use `--wait-ready` on `open-side-surface.sh` and the script handles both this and the "Terminal surface not found" PTY-attach race internally.

The one-call recipe:

```bash
# 1. Open a sibling surface next to the user's current view, NAME it, AND wait
#    until its PTY is attached + shell is actually executing input. --title is
#    what makes the tab findable (see "Name it, then report it by name" below);
#    --wait-ready round-trips a probe (whose send is what attaches the PTY, with
#    no focus steal), exiting 3 with a diagnostic rather than returning a
#    non-ready ref.
# Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md; do not rely on an exported variable.
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
OUT=$("$SKILL_DIR/scripts/open-side-surface.sh" \
        --wait-ready --title "dev server :3000" --json) || exit 2
WS=$(jq -er '.workspace_id | strings | select(length > 0 and . != "null")' <<<"$OUT") || exit 2
SID=$(jq -er '.surface_id | strings | select(length > 0 and . != "null")' <<<"$OUT") || exit 2   # target commands with this
TITLE=$(jq -r '.surface_title' <<<"$OUT")  # tell the user this
WSNAME=$(jq -r '.workspace_name' <<<"$OUT")

# 2. Send the work into it, targeting the surface's UUID. Append \n so it runs.
cmux send --workspace "$WS" --surface "$SID" "ssh user@host\n"
# or: cmux send --workspace "$WS" --surface "$SID" "npm run dev\n"
# or: cmux send --workspace "$WS" --surface "$SID" "cargo watch -x test\n"

# 3. Verify it actually executed — see "Send keystrokes" below for why.
#    --scrollback is not optional here: the bare form follows the user's scroll.
cmux read-screen --workspace "$WS" --surface "$SID" --scrollback --lines 20

# 4. Report it by NAME: "opened '$TITLE' in the '$WSNAME' workspace" — never
#    "opened surface:258".
```

> **Manual fallback** (historical — most callers should use `--wait-ready`):
> if you can't use the script, poll for readiness yourself by sending an
> `echo <unique-marker>` probe and grepping `read-screen` for ≥2 hits of the
> marker (typed input + executed output). Don't rely on a `[$%#>]` prompt
> regex — it silently misses powerline / NerdFont prompts (`❯`, `➜`, custom
> glyphs) and spins to its retry ceiling. Clear the input line with a raw
> `Ctrl-U` (`cmux send --workspace "$WS" --surface "$SID" $'\025'`) before each probe — the line is
> shared with the user, whose keystrokes would otherwise prepend to it. If
> `read-screen` errors before you have sent anything, that is expected: **the
> send is what attaches the PTY.** Probe first, then read; do not reach for
> `cmux focus-pane`, which attaches by stealing the user's focus.

The default `--caller` first uses `cmux identify`, then a live tree lookup of
`CMUX_SURFACE_ID`. When those cannot resolve placement, native Codex and Claude
callers can recover through their exact agent session in `cmux sessions`. Recovery
requires one record, its PID in the tool shell's ancestry with the matching agent
executable, and its tty matching that surface in the current tree. Saved workspace
and active flags do not determine placement. Missing, stale or ambiguous proof
returns a context error; the focused surface is never a substitute.

Wrappers that already know caller identity may supply invocation-scoped
`CMUX_CALLER_SESSION_ID` and `CMUX_CALLER_AGENT` (`codex` or `claude`). These are
validated hints and must agree with native session identity when it is present;
they describe the caller, independently of any agent being launched. Recovery
requires Python 3; existing identify/environment placement works without it.

Use `--focused` on `open-side-surface.sh` when the user says "next to the tab I'm looking at" instead of "next to yours" — the defaults diverge when the user is viewing a different tab than the one the agent lives in.

### Name it, then report it by name (required)

Visibility isn't just "the surface is on screen" — it's "the user can *find* the thing you opened." Two rules, both mandatory for **any** surface, pane, or workspace you create:

**1. Give it a meaningful human-visible title.** A fresh surface inherits a generic auto-title — `zsh`, the cwd basename, or the workspace's own name — which is indistinguishable from every other tab. Name it for the activity, 2–5 words, no trailing punctuation (`dev server :3000`, `ssh prod-web1`, `tail nginx logs`, `pytest watch`). Never leave it as the tool (`zsh`, `node`, `claude`) or as a placeholder word like `workspace` or `test`. The companion `auto-rename` skill has the full naming rubric.

```bash
# Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md; do not rely on an exported variable.
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
# Preferred — one call, title applied at creation:
"$SKILL_DIR/scripts/open-side-surface.sh" --wait-ready --title "dev server :3000" --json

# Any other creation path — name it immediately afterward:
cmux rename-tab --workspace <ws-uuid> --tab <surface-uuid> "dev server :3000"
cmux rename-workspace --workspace <ws-uuid> "lindris frontend"   # if you created the workspace
```

**2. Report the title plus its workspace — never a bare positional ref.** `surface:258` is an internal handle: cmux's UI never displays it, it renumbers as tabs open and close, and the user has no way to search for it. What locates a tab for a human is its **title** + the **workspace name** it lives under (+ which **window**, when more than one cmux window is open — `cmux list-windows`; note cmux exposes no window *title* via the CLI, so anchor a window by the workspace it's currently showing).

```
✅ Opened "dev server :3000" in the "lindris frontend" workspace, right of your pane.
❌ Opened surface:258.
```

**Real failure this prevents:** an agent opened a test surface whose title *and* workspace were both the generic word "workspace", then reported only `surface:258`. Correct handle, zero information — the user could not find the tab, and the report was useless.

**If the names themselves aren't distinguishing, that's still a failure.** A title or workspace name that is generic (`workspace`, `zsh`, `test`) or duplicated across several tabs is not a locator. Fix it rather than reporting it: rename the surface, rename the workspace too if you created it, or — if it's a pre-existing workspace you shouldn't rename — give the user a concrete visible anchor instead ("the tab immediately right of the one you're in, in the window showing *cmb security*"). Verify with `cmux tree --workspace <ws-uuid>` that the title you intended is the title that's actually there before you report it.

### Point the user at a surface that already exists: mark it

A text locator ("the *cmb security* workspace, left pane, tab 2/3") still makes the user scan a sidebar full of similar names. When you send the user to a specific existing workspace or tab (a session waiting on them, the one a question is about), **mark it so they can find it by sight**, and put the marker's wording in your message ("the orange workspace with the 👉 pill"). The marker goes with the locator; it doesn't replace it.

```bash
WS=<workspace-uuid>; SURF=<surface-uuid>; WIN=<window-uuid>   # all from one tree --id-format both snapshot
PRIOR=$(cmux sidebar-state --workspace "$WS" --window "$WIN" | sed -n 's/^color=//p')   # "none" or "#RRGGBB": save it to restore later
cmux workspace-action --action set-color --color Orange --workspace "$WS" --window "$WIN"
cmux set-status cue_pointer "👉 <what they need to do>" --icon hand.point.right.fill \
  --color "#E67E22" --priority 100 --workspace "$WS" --window "$WIN"
cmux trigger-flash --workspace "$WS" --surface "$SURF" --window "$WIN"                   # flashes the exact pane
```

- **Workspace color** is what stands out most in the sidebar. It replaces any color the user already gave the workspace, which is why you read `PRIOR` first.
- **Status pill**: use the fixed key `cue_pointer` so you only ever clear your own pill. The label says what the user needs to do there, not the session's name. The workspace row already shows the name.
- **Flash** picks out the right pane once the user switches to that workspace. It's temporary, and it leaves notifications and unread state alone.
- **Don't rename the tab to mark it** (e.g. a `$`/`👉` prefix). Renaming replaces the title the user and the agent's own title updates rely on, and `tab-action --action clear-name` can only restore it if the tab had no custom name before. Only add a prefix to a tab you created and named yourself.

**Unmark once the user has acted** (they answered, or took over the session), or before you mark a different target. Two pointers at once defeat the point:

```bash
[ "$PRIOR" = none ] && cmux workspace-action --action clear-color --workspace "$WS" --window "$WIN" \
                    || cmux workspace-action --action set-color --color "$PRIOR" --workspace "$WS" --window "$WIN"
cmux clear-status cue_pointer --workspace "$WS" --window "$WIN"
```

Don't move the user's focus to the target unless they ask. Their next keystrokes would go into that session. When they do ask ("take me there", or a `jump` answer), one call does the whole trip: it switches windows, selects the workspace even if it wasn't selected, and selects the tab inside its pane.

```bash
cmux focus-panel --panel <surface-uuid> --workspace <ws-uuid> --window <window-uuid>
cmux identify --json --id-format both | jq -c '.focused | {window_id, workspace_id, surface_id}'   # confirm it landed
```

Pass `--workspace` and `--window`. Without them cmux searches only the caller's workspace, returns `not_found: Surface not found`, and doesn't move focus. Use `focus-panel`, not `focus-pane`: `focus-pane` reaches the pane but shows whichever tab that pane already had selected.

### When to break the default (escape hatches)

Flip to a separate-workspace path **only** when the user explicitly asks for it. Trigger phrases:

- "in a new workspace" / "as its own tab" → `cmux new-workspace --name "..." [--cwd <path>] [--command "..."]`
- "in a separate window" / "open a new cmux window" → `cmux new-window`
- "open a full cmux ssh workspace to X" / "I need drag-drop / remote browser / relay for agent X" → `cmux ssh <host>` (see [references/ssh.md](ssh.md))

When you pick a hidden path deliberately, **tell the user the new surface isn't visible yet** and how to reach it (tab switch, window focus). Surprise hiding is the failure mode this section exists to prevent. Naming matters *more* on these paths, not less — a hidden tab is only reachable if it has a name: always pass `--name` to `new-workspace` / `cmux ssh`, then name the surface inside it, and give the user both names in your report ("switch to the *deploy staging* workspace, tab *ansible run*").

### The `cmux ssh` decision

`cmux ssh <host>` does a lot — relay daemon, browser routing through the remote's network, drag-drop uploads via `scp`, remote `cmux` calls relayed to your local sidebar — but it **always creates a new workspace**, so the session is behind a tab the user has to switch to. Two paths:

| User's intent | Right tool | Why |
|---------------|-----------|-----|
| "ssh to host X to check a log / run a command / poke around" | side-by-side + plain `ssh` (default recipe above) | Visible immediately; plain SSH is enough for read/send/observe. |
| "ssh to host X and run a coding agent" / "I need to drag files to the remote" / "I want the browser to hit the remote's localhost" | `cmux ssh <host>` (+ warn user it opens in a new workspace) | Needs the relay daemon and workspace integration. Worth the tab-switch cost. |

If the user's request is ambiguous ("ssh into host X"), default to the visible side-by-side path. Plain `ssh` in a split gives you everything you need to read output and send commands, and the user can actually see it happen.

---

## Workflow: open a side-by-side surface in the current window

This is the mechanics behind the [default visibility principle](#default-principle-make-new-work-visible-to-the-user) above. Use it for any "open / start / ssh / run" request that doesn't explicitly ask for a separate workspace. The bundled helper handles the decision tree (split vs. add-to-adjacent-pane) so you don't have to hand-roll it:

```bash
# Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md; do not rely on an exported variable.
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
"$SKILL_DIR/scripts/open-side-surface.sh" [OPTIONS]
```

Requires `jq` (macOS: `brew install jq`). The script fails fast with a clear message if missing.

Key options (run `--help` for the full list):

- `--caller` (default) — open next to the agent's own pane. Use when the user says *"next to mine"*.
- `--focused` — open next to the pane the **user** is currently looking at. Use when the user says *"next to what I'm looking at"*. `caller` and `focused` usually coincide but diverge when the user is viewing a different tab than the one the agent lives in.
- `--type terminal|browser` (default terminal).
- `--url <url>` — for browser surfaces.
- `--title <text>` — **pass this every time.** Applies the title with `cmux rename-tab` at creation, so the tab is findable and the returned `surface_title` is something you can report. Omitting it leaves a generic auto-title and prints a hint on stderr; `title_status` in the JSON tells you whether it was `applied`, `failed`, or `unset`.
- `--json` — emit `{surface_ref, surface_id, pane_ref, pane_id, workspace_ref, workspace_id, surface_title, workspace_name, title_status, mode, subject, surface_type, url, ready}` for chaining. Chain on the `*_id` UUIDs (`surface_id`, `workspace_id`), not the `*_ref` positional labels — and report `surface_title` + `workspace_name` to the user, never the refs.
- `--wait-ready` — for terminal surfaces, block until the PTY is attached *and* the shell is actually executing input. The probe send is what attaches the PTY (`Ctrl-U`, then `echo <marker>`, re-sent until the marker appears twice); it does **not** focus the surface. Without this you have to hand-roll a readiness loop and dodge the "Terminal surface not found" race. No-op for browser surfaces.
- `--wait-ready-timeout <seconds>` — override the wait-ready budget (default 30 seconds). On timeout, either creation path attempts to close its own surface by its creation UUID.

On success it prints the new surface's ref + pane + workspace, its `title:` and `workspace:` names, plus which branch it took (`new-surface` vs `new-pane`). Failure goes to stderr with exit 1 (cmux error), 2 (context error), 3 (`--wait-ready` timed out), or 4 (creation identity unavailable).

### What it decides under the hood

Keep this as a mental model — you can still hand-roll a variant when the user's request is non-standard (e.g., split left instead of right).

1. Read the subject's `pane_ref` + `workspace_ref` from `cmux identify --json`.
2. Enumerate panes in that workspace (via `cmux tree --all --json --id-format both`, sorted by index). `--id-format both` is not optional: without it every pane `.id` comes back `null`, leaving you nothing but a positional ref to target by.
3. Branch:
   - **Only one pane** → `cmux new-pane --direction right --type <t> [--url <u>] --workspace <ws>`. (Uses `new-pane` rather than `new-split` because only `new-pane` supports `--type browser`.)
   - **Multiple panes** → pick your-pane-index **+ 1** (fall back to **− 1** if you're rightmost), then `cmux new-surface --pane <adjacent-pane-UUID> --type <t> [--url <u>] --workspace <ws> --window <win>`. The new surface becomes a tab in that existing pane column and auto-selects.

   **Pin `--workspace`, and `--window` for new-surface, with UUIDs.** `new-surface` looks the pane up *inside* a workspace context that defaults to `$CMUX_WORKSPACE_ID` (see `cmux new-surface --help`), and that scoping applies to a **pane UUID exactly as it does to a positional `pane:N`** — a valid UUID whose workspace is not the inherited one comes back `not_found: Pane not found`, and a valid ref in the wrong context comes back `not_found: Workspace not found`. An agent-spawned surface inherits the workspace id of whoever spawned it, not the one its own pane lives in, so pin the container explicitly rather than letting cmux infer it. Prefer UUIDs on top of that, because positional refs renumber as surfaces open and close: the pane ref you read in step 2 can denote something else by step 3. The workspace and window `.id`s sit in the same snapshot as the pane's — carry them and refuse creation if a required UUID is missing.

### Why not always `new-split` / `new-pane`?

Creating a new pane column when an adjacent one already exists shoves your surface into a third column and shrinks everything. Adding a surface to an existing adjacent pane reuses the real estate the user has already allocated.

### Caveat: mixed horizontal/vertical layouts

`tree`'s pane index order tracks visual left-to-right for horizontal splits. For workspaces with mixed horizontal + vertical splits the ordering may not match visual adjacency cleanly — and `tree` **cannot tell you the split orientation or divider ratio at all** (it flattens to a `panes[]` list with no `direction` and no nesting). When you genuinely need to know *how* a workspace is split, `cmux layout get <name>` is the only source of that geometry — see [references/layouts.md](layouts.md). If the user's layout looks non-trivial, verify with `cmux tree --workspace <target-workspace-uuid>` after the call. If you specifically need a fresh pane column instead of a tab inside an existing pane, bypass the script and call `cmux new-pane --direction right --type <terminal|browser>` directly — the script's branching is pane-count-only and won't force a new column when other panes exist.

### Verify

The script consumes creation JSON UUIDs directly; display refs are optional. Re-confirm with `cmux tree --workspace <target-workspace-uuid>` if you need to see it in situ — the new ref should appear under the expected pane with `[selected]` on it, **carrying the title you asked for**. A ref sitting there under a generic auto-title means the rename didn't land; fix it before reporting (see [Name it, then report it by name](#name-it-then-report-it-by-name-required)).

---
