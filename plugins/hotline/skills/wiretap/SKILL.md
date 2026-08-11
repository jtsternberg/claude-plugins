---
name: hotline-wiretap
description: "Return the path to this session's JSONL conversation transcript — 'where is my transcript', 'open/show the transcript'."
allowed-tools: Bash
---

# Hotline: Wiretap

Locate the JSONL transcript file for the current Claude Code session. On current Claude Code (>= 2.1.132) this resolves natively in a single call; older clients fall back to the legacy fingerprint discovery.

## Script Paths

Resolve plugin paths first:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
```

This sets `HOTLINE_SCRIPTS` (and others). Use `$HOTLINE_SCRIPTS` in all script references below.

## Locate the Transcript

One Bash call resolves it on current Claude Code:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")" && \
bash "$HOTLINE_SCRIPTS/session-init.sh" --expanded
```

On current Claude Code the script reads the native `CLAUDE_CODE_SESSION_ID` and derives the transcript path from the project-directory convention — no fingerprinting involved.

Parse the JSON output:

- `{"status": "cached", "session_id": "...", "transcript_path": "...", ...}` — done. This is the normal outcome on current Claude Code. Skip to **Report**.
- `{"status": "cached", "caller_kind": "codex" | "override", ...}` with **no** `transcript_path` — identity resolved, but this rung carries no Claude transcript path (Codex threads don't have one; overrides are harness-agnostic). Report the session ID and tell the user a transcript path isn't derivable here.
- `{"status": "planted", "fingerprint": "..."}` — legacy client fallback (pre-2.1.132 Claude, or a stripped environment). Save the fingerprint and proceed to **Legacy Step 2** in a **separate tool call**.
- `{"status": "error", "message": "..."}` — report the error to the user. Discovery failed.

## Legacy Step 2: Discover from Fingerprint

Only needed when the previous call returned `planted`. **This MUST be a separate Bash tool call** — the fingerprint is written into the transcript when the first tool call returns, so it won't exist yet if both steps run in one shell.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")" && \
bash "$HOTLINE_SCRIPTS/session-init.sh" --expanded discover "<fingerprint>"
```

Replace `<fingerprint>` with the planted value.

Parse the JSON output:

- `{"status": "discovered", "session_id": "...", "transcript_path": "...", ...}` — got it. Proceed to **Report**.
- `{"status": "error", "message": "..."}` — report the error. Discovery failed.

## Report

The `transcript_path` field from the JSON response is the full path to the JSONL file. Tell the user:

> Your session transcript is at:
> ```
> <transcript_path>
> ```

If the file doesn't exist at that path, let the user know.

## --open Flag

If the user passed `--open` (or asked to "open" the transcript), also open the file. Substitute the `transcript_path` value from the JSON — shell state does not survive between tool calls, so the assignment must be in this block:

```bash
TRANSCRIPT_PATH="<transcript_path>"
if [[ "$OSTYPE" == "darwin"* ]]; then
  open "$TRANSCRIPT_PATH"
else
  xdg-open "$TRANSCRIPT_PATH"
fi
```

## Important

- **Do not skip the script and hand-build the path from `$CLAUDE_CODE_SESSION_ID` yourself** — the script also handles overrides, legacy clients, and the project-directory munging, and validates the value.
- On the legacy fallback only: steps must stay **two separate tool calls**. Never combine `planted` handling and `discover` into a single Bash invocation.
- The legacy path caches the discovered ID, so subsequent calls return instantly from cache.
