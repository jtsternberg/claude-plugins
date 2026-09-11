---
name: hotline-call-status
description: "Read the hotline call registry — which caller session dialed which callee session, on what transport and host handle. 'who called whom', 'list hotline calls', 'what callees are registered'."
when_to_use: |
  Also when a briefing or orchestration view needs to nest hotline callees under
  the caller that dialed them, or to map a session ID to the workspace it was
  dialed into.
allowed-tools: Bash
---

# Hotline: Call Status

Print the hotline call registry as JSON lines — one object per callee. Read-only: it opens `~/.agents-hotline/sessions/*.json` and touches nothing else. No transcripts, no switchboard process, no registry writes.

Use this instead of reading the registry files directly. It shares one reader with the switchboard server, so both interpret legacy entries and optional fields the same way.

## Read the registry

```bash
# Codex: these paths resolve under Claude Code; substitute the directory
# containing this SKILL.md, then the installed Hotline plugin directory.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$SKILL_DIR/scripts/call-status.sh" --plugin-root "$PLUGIN_ROOT"
```

Pass a registry directory as the trailing argument to read somewhere other than `$HOTLINE_SESSIONS_DIR` / `~/.agents-hotline/sessions`:

```bash
# Codex: these paths resolve under Claude Code; substitute the directory
# containing this SKILL.md, then the installed Hotline plugin directory.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$SKILL_DIR/scripts/call-status.sh" --plugin-root "$PLUGIN_ROOT" /path/to/sessions
```

## Output

One JSON object per line, so `jq` reads it without buffering the whole registry:

| Field | Meaning |
|---|---|
| `caller_session_id` | The session that dialed. Legacy files take it from the filename. |
| `caller_path` | The caller's workspace. `""` when the file never recorded one. |
| `target` | The workspace dialed — the callee's cwd. |
| `callee_session_id` | The session that answered. `""` if registration never captured one. |
| `mode` | `quick_call`, `work_order`, `conference`, … or `unknown`. |
| `started` / `last_contact` | Unix seconds; `0` when absent. |
| `exchange_count` | Prompts delivered on this connection. |
| `host_handle` | Opaque handle a follow-up re-addresses: a cmux surface ref or a herdr agent name. `""` for headless and detached calls. |
| `transport` | `cmux`, `herdr`, … or `""` on entries written before hotline 0.31.0, which means local. |
| `remote` | SSH target when the callee runs on another box; `""` when local. |

Group by `caller_session_id` to nest callees under their caller:

```bash
# Codex: these paths resolve under Claude Code; substitute the directory
# containing this SKILL.md, then the installed Hotline plugin directory.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$SKILL_DIR/scripts/call-status.sh" --plugin-root "$PLUGIN_ROOT" | jq -s 'group_by(.caller_session_id)'
```

## Notes

- An empty or missing registry prints nothing and exits 0 — no dials have been registered, which is not an error.
- A malformed registry file is skipped with a stderr warning and every other entry still comes through. Report the warning; don't repair the file.
- A registry entry is a record of a dial, not proof the callee is still alive. Nothing here probes a session. Ask the transport (cmux, herdr) when liveness matters.
- For a live rendering of both sides of a call, use the `switchboard` skill instead.
