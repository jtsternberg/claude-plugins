# Layouts: the geometry API

`cmux layout` is the **only** part of cmux that exposes and reproduces full split geometry — split orientation, divider ratios, and nesting. Everything else (`tree`, `list-panes`) flattens the picture and loses that structure. Read this file when a task needs to save, inspect, or rebuild an exact layout, or when you need to know *how* a workspace is split (not just what panes it contains).

## Why `tree --json` is not enough

`cmux tree --json` returns a flat `panes[]` list with **no split `direction`, no divider `split` ratio, and no nesting**. A workspace split left/right and one split top/bottom produce byte-identical `tree` output. If you need orientation or divider position, `tree` cannot give it to you — reach for `layout get`.

Verified ordering note: the depth-first leaf order of a `layout get` split tree matches the flat `tree --json` `panes[]` order (tested on 2-pane and mixed horizontal/vertical workspaces), so a positional join between the two is reliable for flat cases. Deep nesting was not exhaustively verified — for anything beyond a couple of splits, trust the `layout get` tree's own structure rather than joining by index.

## Subcommands

Run `cmux layout --help` for the live signatures. As verified against the installed build:

```
cmux layout save <name> [--workspace <ref>] [--overwrite] [--description <text>]
cmux layout list [--json]
cmux layout get <name>
cmux layout open <name> [--cwd <dir>] [--focus <true|false>]
cmux layout delete <name>
```

- **`save`** — snapshot a **live** workspace's geometry into cmux's named-layout store. Requires an existing workspace (`--workspace <ref>`; defaults to the current one). `--overwrite` replaces an existing name; `--description` annotates it. Saved layouts persist in cmux's own store across app/daemon restarts.
- **`list`** — enumerate saved layout names (`--json` for machine-readable).
- **`get`** — print the layout's full geometry as JSON (the split tree below). This is the export mechanism — there is no separate `export` subcommand.
- **`open`** — rebuild a saved layout as a new workspace. `--cwd` relocates every surface's working directory to a new base; `--focus` controls whether the rebuilt workspace takes focus.
- **`delete`** — remove a saved layout from the store.

## The split-tree JSON shape

`layout get` returns a recursive binary-split tree that carries complete geometry. The same shape is accepted inline by `cmux new-workspace --layout '<json>'` and is what `layout open` replays from the store.

**Split node** — an internal node dividing space in two:

- `direction` — `"horizontal"` or `"vertical"`
- `split` — divider ratio, e.g. `0.5` (halfway)
- `children` — an array of **exactly two** nodes; each child is itself a split node or a leaf, so the tree nests recursively.

**Leaf node** — a single pane holding an ordered tab stack:

```json
{ "pane": { "surfaces": [ /* … */ ] } }
```

**Surface** — one entry in a pane's `surfaces[]` (the tab stack, in order):

- `type` — `"terminal"` or `"browser"`
- `cwd` — optional working directory
- `focus` — optional; whether this surface is focused
- `url` — for `browser` surfaces
- `command` — a command run on the surface at creation time (this is how a rebuilt layout seeds each pane's startup command)

### Example

```json
{
  "direction": "horizontal",
  "split": 0.5,
  "children": [
    { "pane": { "surfaces": [ { "type": "terminal", "command": "vim" } ] } },
    { "pane": { "surfaces": [ { "type": "terminal", "command": "npm run start" } ] } }
  ]
}
```

## Rebuilding a whole workspace in one call

`cmux new-workspace --layout '<json>'` takes the same tree inline and rebuilds the entire split structure — seeding each surface's startup command — in a single call. Note that layout-defined surfaces carry their own `command`; the top-level `new-workspace --command` flag is for the simple single-surface case, not for layout builds.

```bash
cmux new-workspace --name Dev --layout '{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","command":"vim"}]}},{"pane":{"surfaces":[{"type":"terminal","command":"npm run start"}]}}]}'
```

`cmux layout open <name>` does the same from the named-layout store (with `--cwd` relocation), so the round trip is: `layout save dev` once → `layout open dev --cwd ~/other/project` any number of times.

## Common workflows

- **Reproduce your current setup elsewhere:** `cmux layout save dev --overwrite` → later `cmux layout open dev --cwd ~/projects/other`.
- **Read the geometry of an existing workspace:** `cmux layout save _tmp --overwrite && cmux layout get _tmp` (save is required first — `get` reads the store, not a live workspace), then `cmux layout delete _tmp`.
- **Build a fixed dev layout on demand without saving it:** compose the tree JSON and pass it to `cmux new-workspace --layout '…'`.
