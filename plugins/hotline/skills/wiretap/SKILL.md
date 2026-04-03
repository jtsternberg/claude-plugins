---
name: hotline-wiretap
description: "Finds and returns the path to the current session's conversation transcript file. Use when the user asks 'where is my transcript?', 'find my transcript', 'open the transcript', 'show transcript path', or wants to locate the JSONL conversation log."
allowed-tools: Bash
---

# Hotline: Wiretap

Locate the JSONL transcript file for the current Claude Code session.

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
bash "$HOTLINE_SCRIPTS/session-init.sh" --include-path
```

Parse the JSON output:

- `{"status": "cached", "session_id": "...", "transcript_path": "...", ...}` — Done. Skip to **Report**.
- `{"status": "planted", "fingerprint": "..."}` — Save the fingerprint value. Proceed to **Step 2** in a **separate tool call**.
- `{"status": "error", "message": "..."}` — Report the error to the user. Discovery failed.

### Step 2: Discover from Fingerprint

**This MUST be a separate Bash tool call** — the transcript needs to flush between steps.

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)" && \
bash "$HOTLINE_SCRIPTS/session-init.sh" --include-path discover "<fingerprint>"
```

Replace `<fingerprint>` with the value from Step 1.

Parse the JSON output:

- `{"status": "discovered", "session_id": "...", "transcript_path": "...", ...}` — Got it. Proceed to **Report**.
- `{"status": "error", "message": "..."}` — Report the error. Discovery failed.

## Report

The `transcript_path` field from the JSON response is the full path to the JSONL file. Tell the user:

> Your session transcript is at:
> ```
> <transcript_path>
> ```

If the file doesn't exist at that path, let the user know.

## --open Flag

If the user passed `--open` (or asked to "open" the transcript), also open the file:

```bash
if [[ "$OSTYPE" == "darwin"* ]]; then
  open "$TRANSCRIPT_PATH"
else
  xdg-open "$TRANSCRIPT_PATH"
fi
```

## Important

- **Two separate tool calls.** Do NOT combine Steps 1 and 2 into a single Bash invocation. The fingerprint is planted in the transcript by the first tool call's output — it won't exist yet if you run both steps back-to-back in one shell.
- The session ID is cached after first discovery, so subsequent calls return instantly from cache.
