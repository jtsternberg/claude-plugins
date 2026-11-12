# Targeting

Read before resolving, reading, or acting on another surface, and before destructive or bulk operations.

## Handle conventions (read before passing IDs)

**Target by UUID. Always resolve a handle to its UUID and pass that UUID to any command that acts on it.** UUIDs are permanent identities for a window/workspace/pane/surface — they name the same object for the life of that object, across every command and every session.

cmux accepts three handle formats anywhere a `window`, `workspace`, `pane`, or `surface` flag appears. Understand all three, and reach for the first:

- **UUIDs** — full identifiers, stable for the object's lifetime. **This is what you pass to commands.**
- **Short refs** — `window:1`, `workspace:2`, `pane:3`, `surface:4`. These are *positional display labels*: an index within scope that cmux reassigns as objects open and close. A ref like `surface:318` names whatever currently sits in that slot, which may be a different object a moment later. Treat refs as human-readable output to show the user, and as throwaway input only within a single read that you immediately act on — resolve to a UUID first whenever the handle outlives one command.
- **Bare indexes** — same positional, reassignable nature as short refs.

`tab-action` additionally accepts `tab:<n>` (also positional).

**Get UUIDs like this:**
- Your own location: `cmux identify --json --id-format both` returns your caller/focused UUIDs (without that flag you get refs only — see above). The `CMUX_*_ID` env vars (`CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_TAB_ID`) are UUIDs too, but they are a **snapshot from the moment your process was spawned** — a surface that has since been moved, re-registered, or superseded leaves them naming something cmux no longer knows, and an agent-spawned surface (a dialed-in callee) is the common case. `identify` can also answer `"caller": null` for exactly that reason, and then it reports the **focused** context, which is somebody else's surface. So confirm the id you intend to act on appears in `cmux tree --all --json --id-format uuids` before you target it, and treat "not in the tree" as unknown location rather than as a usable handle.
- Fresh creations: trust validated UUIDs returned by the creation command; a tree may lag or refs may renumber.
- Anything else: `cmux tree --all --json --id-format uuids` (or `--id-format both` to see refs alongside for a human). Snapshot once, read the UUIDs you need, then target by those.

### An empty or unresolved handle silently targets *you*

**`cmux send --surface "" …` does not fail.** The empty value falls through to the `$CMUX_SURFACE_ID` default, so the payload is delivered to **the caller's own surface** — and when the caller is an agent inside a Claude Code REPL, the text lands in **the user's input box**. Exit code 0, no warning.

This is the failure mode of the standard chaining idiom, because both halves fail quietly:

Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md in the assignment below.

```bash
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
OUT=$("$SKILL_DIR/scripts/open-side-surface.sh" --wait-ready --title "…" --json)   # exit 1, empty stdout
SID=$(jq -r '.surface_id' <<<"$OUT")                                               # "" (or the string "null")
cmux send --surface "$SID" "npm run dev\n"                                         # → lands in YOUR surface
```

**Check the opener's exit status, not just its id.** It refuses rather than handing
back a null id, so the shape a caller has to handle is *no JSON and a non-zero
exit* — and a caller that only tests the parsed id never notices, because an empty
`$OUT` parses to an empty `$SID` exactly like a null one:

Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md in the assignment below.

```bash
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
OUT=$("$SKILL_DIR/scripts/open-side-surface.sh" --wait-ready --title "…" --json) || {
  echo "side surface refused (rc=$?) — see its stderr; a surface may have been left behind" >&2
  exit 2
}
SID=$(jq -r '.surface_id // empty' <<<"$OUT")
[[ -n "$SID" && "$SID" != "null" ]] || { echo "no surface handle — refusing to send" >&2; exit 2; }
```

An `rc 4` means the creation response lacked valid UUIDs or named a mismatched container. The script does not close an untrusted target; inspect the tree to find any orphan.

**Real failure this prevents:** exactly the sequence above, live. A helper exited non-zero with empty output, and the next `send` typed a probe command into the user's prompt box mid-conversation. The only evidence was a `surface.input_sent` event whose `payload.result.surface_id` was the caller's own.

Guard both ends — validate before, verify after:

```bash
[[ -n "$SID" && "$SID" != "null" ]] || { echo "no surface handle — refusing to send" >&2; exit 2; }
[[ "$SID" != "$MY_SURFACE_ID" ]]    || { echo "handle resolved to my own surface" >&2; exit 2; }
```

`jq -r` prints the literal string `null` for a missing key, so a `-n` test alone passes on it. Check for both. Then confirm where it actually landed with `surface.input_sent` — its `payload.result.surface_id` is the surface cmux really resolved, and `payload.params.text_length` is the exact byte count it delivered ([references/events.md](events.md)).

In a shell script, don't hand-roll the check a fourth time: `cmux_handle_ok <what> <handle>` in `plugins/hotline/scripts/repl-state.sh` is the guard this repo already uses for it.

`open-side-surface.sh` will not hand you a null id at all: it takes UUIDs directly from the `new-surface` or `new-pane` creation response, and exits **4** with a diagnostic and no JSON if it cannot identify what it created. Keep the guard above anyway — `identify` and a hand-rolled tree read can each still answer `null`.

**Which surface it substitutes depends on the path.** `cmux send` and the other CLI verbs default their `--surface`/`--workspace` to the `$CMUX_*_ID` env vars, so an empty handle lands on **the caller's own surface**. A malformed `cmux rpc` call — camelCase param keys, which are silently dropped — instead resolves against the **focused** surface and returns `ok:true` carrying somebody else's grid. Either way the call succeeds and the target is not the one you named, which is why the verification is `result.surface_id`, not the exit code.

### Destructive and bulk operations: resolve UUIDs up front

For anything that mutates or removes state — `close-surface`, `close-workspace`, `close-window`, `swap-pane`, `move-surface`, or any loop over several targets — **collect every target UUID in one `tree --json --id-format uuids` snapshot first, then act by UUID.** This is the affirmative rule that keeps bulk operations correct:

1. `cmux identify --json --id-format both` → note your **own** surface/pane UUID, so you can keep it out of the target set (closing the surface your agent runs in kills the agent's tty — the process goes down with the pane). Confirm that id is in the tree snapshot from step 2: an id that isn't there excludes nothing, so the loop would be free to close your own pane. When your own location cannot be confirmed, do not run the bulk operation — name the targets one at a time instead.
2. `cmux tree --all --json --id-format uuids` → collect the target UUIDs.
3. Exclude your own UUID from step 1.
4. Act on each **by UUID**.
5. **Verify by UUID, not by the ref cmux echoes back.** `close-surface` reports an `OK surface:<n>` whose number can already reflect post-close renumbering — a close of `surface:24` printed `OK surface:26`. That is not a sign it closed the wrong thing; it is the same positional-ref instability, showing up in the confirmation. Re-read `tree --json --id-format uuids` and assert the target UUID is gone and yours is still there.

Because UUIDs are permanent, acting on one never changes what the others refer to — so a close-loop stays aimed at exactly the objects you chose. (Positional refs renumber as each object closes, so a ref captured before the loop can point somewhere new mid-loop — including your own pane. UUIDs are immune to that.)

### `--json` works, in either position

`--json` is supported both as a trailing flag and as a **global prefix** — `cmux --json top --all` appears in cmux's own help, and `cmux list-workspaces --json` returns JSON. Verified on cmux 0.64.25.

Still true: coverage is per-command, not universal. `<cmd> --json` is a cheap sniff test — if the output comes back as text, that command doesn't implement it, and `tree` (hierarchy) or `identify` (current context) is the fallback. `cmux tree --all --json --id-format uuids` remains the one call that answers "what exists right now, by UUID".

## Workflow: targeting another surface (find → read → send)

One of the most common agent tasks: the user says *"read what's happening in the other tab"* or *"that workspace over there — send it this command."* You're running inside one surface (your own `CMUX_SURFACE_ID`) and need to act on a different one. The mechanics:

**A bare identifier is a read request.** Invoked with only a surface UUID, `surface:N` ref, or tab title and no verb — resolve it, read its screen, and report back (title + workspace + a summary of what's on it). Don't stop to ask what to do with it; that's the default action. Only ask when the identifier can't be resolved. See Step 2 for the read command.

### Step 1 — Find the surface

**When the user names a surface, just pass the name as a bare query — don't reach for `read-screen` or list everything.** The script picks the strategy:

```bash
# Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md; do not rely on an exported variable.
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
"$SKILL_DIR/scripts/find-surface.sh" "✳ hotline: claude-plugins → Automating (quick_call)" --json
```

A bare query (no flag) matches by **title first** — one `cmux tree` call, no screen reads — and only falls back to a content scan if the title pass is dry. Paste the tab label **verbatim**: leading status glyphs (`✳`, spinners) and surrounding whitespace are stripped from both sides before comparing, so the match holds even if the glyph has since changed. An **exact** (normalized) title match wins over substring matches — if exactly one surface's title equals the query, only that one is returned; for path-shaped titles the query may also equal just the **basename** (final path segment), so a query like `lindris-monorepo` resolves to the `~/Sites/lindris-monorepo` workspace tab rather than also matching a hotline tab that merely contains it. A unique hit is your answer; act on it immediately.

Reach for an explicit flag only when the bare query isn't the right shape:
- **`-w <name>`** — user pointed at a *workspace* ("in my 'debug lindy' workspace"); narrows before searching.
- **`-c <text>`** — user described *on-screen text*, not a title ("the tab hitting the 500 error"). This is the only mode that reads screens per candidate (the slow path) — scope it with `-w` when you can.
- **`-t <title>`** — same title-matching as the bare query, when you want to force title-only with no content fallback.

Use the bundled helper rather than hand-parsing `cmux tree --all`:

```bash
# Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md; do not rely on an exported variable.
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
"$SKILL_DIR/scripts/find-surface.sh" [OPTIONS]
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
# Both harnesses: substitute the installed cmux-cli plugin directory resolved from the invoking SKILL.md; do not rely on an exported variable.
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/using-cmux-cli"
match=$("$SKILL_DIR/scripts/find-surface.sh" -w cmux -c "500 error" --json | jq -r '.[0]')
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

After sending, re-read with `cmux read-screen --workspace "$WS_ID" --surface "$SURF_ID" --scrollback --lines 50` to confirm the effect landed. Don't trust exit codes — cmux's `send` succeeds whether or not the remote process did anything useful with the input. If the re-read shows a `Jump to bottom` / `Press up to edit queued messages` marker, the view is scrolled and your capture is stale — don't read that as a failed send ([details](terminal-io.md#gotcha-read-screen-returns-the-scrolled-viewport-not-the-live-bottom)).

### Gotcha: which workspace does a given surface live in?

`find-surface.sh` already pairs each surface with its workspace — use the `workspace_id` it returns as the `--workspace` value for the follow-up `read-screen`/`send`. Hand-parsing `cmux list-pane-surfaces` loses this pairing; prefer the script.

---
