---
name: hotline-wiretap
description: "Finds and returns the path to the current session's conversation transcript file. Use when the user asks 'where is my transcript?', 'find my transcript', 'open the transcript', 'show transcript path', or wants to locate the JSONL conversation log."
allowed-tools: Bash
---

# Hotline: Session Transcript

Locate the JSONL transcript file for the current Claude Code session. Requires session ID discovery first, then constructs the path from the project directory hash.

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

- `{"status": "cached", "session_id": "..."}` — You already know the ID. Skip to **Build Path**.
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

- `{"status": "discovered", "session_id": "..."}` — Got it. Proceed to **Build Path**.
- `{"status": "error", "message": "..."}` — Report the error. Discovery failed.

## Build Path

Construct the transcript path and verify it exists:

```bash
PROJECT_HASH=$(pwd | sed 's|[^a-zA-Z0-9-]|-|g')
TRANSCRIPT_PATH="$HOME/.claude/projects/${PROJECT_HASH}/<session_id>.jsonl"
if [[ -f "$TRANSCRIPT_PATH" ]]; then
  echo "FOUND: $TRANSCRIPT_PATH"
else
  echo "NOT FOUND: $TRANSCRIPT_PATH"
fi
```

Replace `<session_id>` with the discovered session ID.

## Report

Tell the user their transcript path:

> Your session transcript is at:
> ```
> <transcript_path>
> ```

If the file was not found, let the user know and suggest the path may differ.

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
