---
name: hotline-switchboard
description: "Serves a live, read-only HTML dashboard of all hotline conversations — the switchboard. Use when the user asks to 'open the switchboard', 'watch the hotline calls', 'show hotline conversations', 'monitor the calls', or wants a live view of cross-workspace Claude conversations. Also handles 'stop the switchboard' and 'is the switchboard running?'."
allowed-tools: Bash
---

# Hotline: Switchboard

A local dashboard that shows every hotline call — who dialed whom, live/recent/stale status — and renders both ends of a call side-by-side, updating in real time as the conversations evolve. Strictly view-only: it tails the Claude Code transcript files, never writes.

## How it works

- Call registry: `~/.agents-hotline/sessions/*.json` (caller, callees, session IDs, modes).
- Transcripts: each session ID maps to `~/.claude/projects/*/<session-id>.jsonl`, which Claude Code appends to live. The server tails these from byte offsets and streams new entries to the browser over SSE.
- Zero dependencies: single-file Node server, inline HTML/JS UI, no build step.

## Commands

All via one script:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/switchboard.sh start [--port=4160] [--no-open]
bash ${CLAUDE_SKILL_DIR}/scripts/switchboard.sh stop
bash ${CLAUDE_SKILL_DIR}/scripts/switchboard.sh status
```

Each prints a JSON status line. `start` backgrounds the server (pidfile at `~/.agents-hotline/switchboard.pid`, log at `~/.agents-hotline/switchboard.log`) and opens the browser unless `--no-open` is passed. `start` always replaces any prior switchboard instance on the port (pidfile-tracked or ad-hoc) so it serves fresh code — it doubles as a restart.

## Usage

- **"Open the switchboard" / "watch the calls"** → run `start`, then report the `url` from the JSON output.
- **"Stop the switchboard"** → run `stop`.
- **"Is the switchboard running?"** → run `status`.
- Custom port: pass `--port=<n>` or set `HOTLINE_SWITCHBOARD_PORT`.

## Notes

- Requires Node.js (`node` on PATH). If missing, `start` reports an error — tell the user to install Node.
- The board groups calls into **live** (activity in the last 15 min), **recent** (< 24h, tune with `--stale-hours` on the server), and **stale**.
- If a session's transcript can't be found (deleted, or the session was compacted into a new ID), the lane shows "No transcript found" — this is expected for old registry entries, not a bug.
