---
name: hotline-caller-id
description: "Discovers and returns the current Claude Code session ID. Use when the user asks 'what is your session ID?', 'what session is this?', 'give me your session ID', or any variation of asking for the current conversation's session identifier."
allowed-tools: Bash
---

# Hotline: Session ID

Discover your own Claude Code session ID. Claude Code doesn't expose this natively, but Hotline's fingerprint-and-grep method can find it.

## Script Paths

Resolve plugin paths first:

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)"
```

This sets `HOTLINE_SCRIPTS` (and others). Use `$HOTLINE_SCRIPTS` in all script references below.

## Discovery Protocol

This is a **two-step process** that requires **two separate Bash tool calls**. The fingerprint must be written into the transcript (which happens when the first tool call returns) before it can be found.

### Step 1: Check Cache or Plant Fingerprint

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)" && \
bash "$HOTLINE_SCRIPTS/session-init.sh"
```

Parse the JSON output:

- `{"status": "cached", "session_id": "..."}` — You already know the ID. Skip to **Report**.
- `{"status": "planted", "fingerprint": "..."}` — Save the fingerprint value. Proceed to **Step 2** in a **separate tool call**.
- `{"status": "error", "message": "..."}` — Report the error to the user. Discovery failed.

### Step 2: Discover from Fingerprint

**This MUST be a separate Bash tool call** — the transcript needs to flush between steps.

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)" && \
bash "$HOTLINE_SCRIPTS/session-init.sh" discover "<fingerprint>"
```

Replace `<fingerprint>` with the value from Step 1.

Parse the JSON output:

- `{"status": "discovered", "session_id": "..."}` — Got it. Proceed to **Report**.
- `{"status": "error", "message": "..."}` — Report the error. Discovery failed.

## Report

Tell the user their session ID:

> Your session ID is: `<session_id>`
>
> You can resume this conversation with:
> ```
> claude --resume <session_id>
> ```

## Important

- **Two separate tool calls.** Do NOT combine Steps 1 and 2 into a single Bash invocation. The fingerprint is planted in the transcript by the first tool call's output — it won't exist yet if you run both steps back-to-back in one shell.
- The session ID is cached after first discovery, so subsequent calls return instantly from cache.
