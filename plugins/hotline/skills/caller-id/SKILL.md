---
name: hotline-caller-id
description: "Return the current Claude Code session ID — 'what is your/this session ID?'"
allowed-tools: Bash
---

# Hotline: Session ID

Discover your own session ID. On current Claude Code (>= 2.1.132) this resolves natively in a single call; older clients fall back to Hotline's legacy fingerprint-and-grep discovery.

## Script Paths

Resolve plugin paths first:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
```

This sets `HOTLINE_SCRIPTS` (and others). Use `$HOTLINE_SCRIPTS` in all script references below.

## Resolve Identity

One Bash call resolves identity on every current harness:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")" && \
bash "$HOTLINE_SCRIPTS/session-init.sh"
```

The script checks, in order: an explicit `HOTLINE_CALLER_SESSION_ID` override, Claude Code's native `CLAUDE_CODE_SESSION_ID` (exported into every Bash subprocess since 2.1.132), Codex's `CODEX_THREAD_ID`, and only then the legacy fingerprint path.

Parse the JSON output:

- `{"status": "cached", "session_id": "...", "caller_kind": "native"}` — done. This is the normal outcome on current Claude Code (`caller_kind` may also be `override` or `codex`; a legacy fingerprint cache hit omits the field entirely). Skip to **Report**.
- `{"status": "planted", "fingerprint": "..."}` — legacy client fallback (pre-2.1.132 Claude, or a stripped environment). Save the fingerprint and proceed to **Legacy Step 2** in a **separate tool call**.
- `{"status": "error", "message": "..."}` — report the error to the user. Discovery failed.

## Legacy Step 2: Discover from Fingerprint

Only needed when the previous call returned `planted`. **This MUST be a separate Bash tool call** — the fingerprint is written into the transcript when the first tool call returns, so it won't exist yet if both steps run in one shell.

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")" && \
bash "$HOTLINE_SCRIPTS/session-init.sh" discover "<fingerprint>"
```

Replace `<fingerprint>` with the planted value.

Parse the JSON output:

- `{"status": "discovered", "session_id": "..."}` — got it. Proceed to **Report**.
- `{"status": "error", "message": "..."}` — report the error. Discovery failed.

## Report

Tell the user their session ID:

> Your session ID is: `<session_id>`
>
> You can resume this conversation with:
> ```
> claude --resume <session_id>
> ```

## Important

- **Let the script report the ID, even when `$CLAUDE_CODE_SESSION_ID` is right there in your environment.** It resolves the override and Codex rungs too, falls through to the legacy path when the native value is missing, and validates what it finds — echoing the variable yourself gets none of that, and passes a malformed value straight through.
- **On the legacy fallback, `planted` and `discover` go in two separate Bash tool calls.** The fingerprint only reaches the transcript when the first call returns, so a single combined invocation searches for something that isn't written yet.
- The legacy path caches the discovered ID, so subsequent calls return instantly from cache.
