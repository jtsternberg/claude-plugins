---
name: auto-rename
description: "Use when the user wants a cmux tab or workspace renamed to something meaningful without dictating the name — 'rename this tab', 'auto-rename', 'name this workspace something useful', 'fix these tab names', 'name my workspaces', or when tabs/workspaces have default/stale names (zsh, Terminal, bash, node) that should reflect what's actually running there."
argument-hint: "[tab | workspace | both | all] [optional target hints]"
allowed-tools:
  - "Bash(cmux *)"
  - "Bash(which cmux)"
  - "Bash(jq *)"
---

# Auto-rename cmux tabs & workspaces

Summarize what a cmux tab (surface) or workspace is actually doing, generate a concise helpful name, and apply it with `cmux rename-tab` / `cmux rename-workspace`.

**REQUIRED BACKGROUND:** the companion `using-cmux-cli` skill covers handle formats, `identify`, `tree`, `read-screen`, and its gotchas (especially the Claude Code ghost-autosuggest trap). This skill assumes that vocabulary.

## Current context (resolved at skill load)

```!
cmux identify --json --id-format both 2>/dev/null || echo '{"error":"cmux identify failed — outside cmux or socket unreachable"}'
```

`--id-format both` gives each entry its stable UUID (`*_id`) alongside its positional `*_ref`. Target by the UUID.

- `caller.*` — where this agent runs. Default target for "rename **this** tab/workspace".
- `focused.*` — where the user is looking. Target this when they say "the tab I'm looking at".

## Step 1 — Resolve the target(s)

| User says | Target |
|-----------|--------|
| "rename this tab" / "auto-name my tab" | `caller.tab_id` (UUID) |
| "rename this workspace" | `caller.workspace_id` (UUID) |
| "rename both" / bare "auto-rename" | caller tab **and** caller workspace |
| "the tab/workspace I'm looking at" | `focused.*` |
| "the tab running the build" / a named workspace | find it: `cmux tree --all --json` + `jq`, or the using-cmux-cli `find-surface.sh` helper |
| "all my workspaces" / "fix all the tab names" | batch mode — iterate `cmux tree --all --json` |

**Gotcha (verified):** `cmux tree --workspace <ref> --json` ignores the workspace filter and returns the whole tree — grabbing the first surface from it targets the wrong workspace and `rename-tab` fails with `not_found: Tab not found`. Either use the plain-text `cmux tree --workspace <ref>` (which *is* scoped) or filter the JSON yourself by UUID: `cmux tree --all --json --id-format both | jq --arg w "<ws-uuid>" '.. | objects | select(.id==$w)'`.

## Step 2 — Gather evidence for the name

**If the target is this agent's own tab/workspace, you already know the task from the conversation — skip read-screen and name it from what you're actually working on.**

Otherwise, read what's happening there:

```bash
cmux read-screen --workspace <ws-id> --surface <surface-id> --scrollback --lines 200
```

Supplement for workspaces (cwd, git branch, ports, status pills tell you the project even when screens are quiet):

```bash
cmux sidebar-state --workspace <ws-id>
cmux tree --workspace <ws-id>   # existing tab titles are evidence too
```

### Agent sessions (claude / codex / opencode / etc.)

If the scrollback shows an agent REPL, name it after the **task the session is doing**, not the tool. Read the most recent user prompt and assistant activity in the scrollback and distill the task.

- ❌ "claude session", "codex" — says nothing
- ✅ "fix lindris 500s", "gws gmail-read skill"

**Ghost-autosuggest warning:** agent REPLs render a grayed next-prompt suggestion inside the input box that looks like real user input in `read-screen` output. Text sitting alone in the prompt with no output below it is a suggestion, not the task. Base the name on prompts that have responses under them.

### Non-agent terminals

Evidence, in order of usefulness: the running foreground command (dev server, tail, ssh host, tests), recent commands + output in scrollback, then cwd/branch from `sidebar-state`. A browser surface names itself after the page/site.

## Step 3 — Generate the name

Rules:

- **2–5 words**, scannable in a tab bar; no trailing punctuation.
- Name the **activity or subject**, never the shell/tool: not "zsh", "terminal", "claude", "node".
- **Tab** names say what that surface does: `dev server :3000`, `ssh prod-web1`, `tail nginx logs`, `tests (watch)`.
- **Workspace** names say the project/mission, usually anchored on repo or task: `lindris frontend`, `gws gmail-read skill`.
- When tab and workspace are both renamed, don't duplicate — workspace carries the project, tab carries the activity.
- Idle/empty shell with nothing to go on → name by cwd/branch (e.g. `claude-plugins`), or leave it and say so rather than inventing something.

## Step 4 — Apply

```bash
cmux rename-tab --workspace <ws-id> --tab <tab-id> "name here"
cmux rename-workspace --workspace <ws-id> "name here"
```

**Pass explicit handles you resolved *this run* from `cmux identify --json --id-format both` — even when renaming your own tab.** Use `caller.workspace_id` + `caller.tab_id` (UUIDs). A freshly-resolved UUID is verified to work here (`rename-tab --workspace <ws-id> --tab <tab-id>` applies correctly). The failure mode to avoid is the **stale env-var default**: a bare `cmux rename-tab "name"` (no explicit handle) run from inside the tab being renamed has returned `Error: not_found: Tab not found` in practice — because `$CMUX_TAB_ID`/`$CMUX_SURFACE_ID` were captured at spawn and can go stale, not because UUIDs don't work. Resolve fresh, pass the UUID.

To clear a tab name back to automatic: `cmux tab-action --action clear-name --tab <tab-id>`.

## Step 5 — Verify

```bash
cmux tree --workspace <ws-id>
```

Confirm the new title actually appears. Then tell the user what each thing was named and (briefly) why.

## Batch mode ("name all my workspaces")

1. `cmux tree --all --json --id-format both` → list workspaces with their UUIDs (and surfaces/titles). Collect the `.id` of every workspace/tab you'll rename in this one snapshot, then rename by UUID — refs renumber as you go, UUIDs don't.
2. Per workspace: `sidebar-state` + `read-screen` on the selected/likeliest surface; skip ones already well-named unless asked to redo everything.
3. Rename, then one final `cmux tree --all` to show the result.

For many workspaces, keep reads shallow (`--lines 60` first, deeper only when inconclusive).

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Naming after the tool ("claude", "zsh") | Name the task/subject the tool is working on |
| Trusting the ghost autosuggest as the session's task | Only use prompts that have output beneath them |
| Omitting `--workspace`/`--tab` and hitting `not_found: Tab not found` | The stale env-var default is the culprit, not the UUID format; resolve a fresh `caller.workspace_id`/`caller.tab_id` from `identify --id-format both` and pass those |
| Long sentence names | 2–5 words; tab bars truncate |
| Inventing a name for an idle shell | Fall back to cwd/branch, or say there's nothing to name it from |
