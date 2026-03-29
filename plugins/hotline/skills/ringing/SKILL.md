---
name: hotline-ringing
description: "Receiver-side handshake for incoming hotline calls. Primes the agent with communication protocol context. Invoked as /hotline-ringing on first contact from another workspace."
---

# Hotline: Ringing — Incoming Call Protocol

You are receiving a **hotline call** from another Claude Code agent running in a different workspace. This is a cross-workspace communication initiated by the `hotline-dial` skill.

## What's Happening

Another agent (the "caller") needs your help. They've connected to your workspace because you have knowledge, files, or capabilities they need. Your job is to be a helpful collaborator.

## Script Paths

- `PLUGIN_SCRIPTS` = the `scripts/` directory at the root of this plugin (sibling to `skills/`)

## Incoming Prompt Format

The caller's prompt follows this structure:

```
/hotline-ringing [MODE: quick_call|work_order|conference_call] [CALLER: <workspace-path>] [SESSION: <session-id>]
<the actual request>
```

Parse the `MODE`, `CALLER`, and `SESSION` from the prompt metadata. Use them for logging and to determine your response style.

## Communication Protocol

### Call Modes

Respond based on the MODE from the incoming prompt:

**Quick Call** — The caller needs a quick answer. Read their question, provide a concise response, and you're done. Think phone call, not meeting.

**Work Order** — The caller is delegating a task to you. Acknowledge it, do the work in your workspace, and report back with results. You have full autonomy to read files, run commands, and make changes as needed.

**Conference Call** — The caller wants to collaborate back-and-forth. Expect multiple exchanges. Each follow-up arrives via `--resume` on the same session. Work together iteratively until the task is complete.

### Response Guidelines

- Be concise. The caller is another agent, not a human — skip pleasantries.
- If you're working on a work order, provide a clear status: what you did, what the result was, whether it's complete.
- If you need clarification, ask in your response. The caller will relay to the user if needed.
- If the task is outside your workspace's scope, say so — the caller may have dialed the wrong workspace.

### Response Format

Structure your response based on mode:

**Quick call:**
```
[Your answer — concise and direct]
```

**Work order:**
```
[What you did and the result]

STATUS: WORK_COMPLETE
```
Or if you need another exchange:
```
[Progress update and what's remaining]

STATUS: WORK_IN_PROGRESS
```

**Conference call:**
```
[Your response to this exchange — no status signal needed]
```

## Logging

After handling the call, log it to the dial history:

```bash
bash "PLUGIN_SCRIPTS/dial-history.sh" append \
  --session "<SESSION from prompt>" \
  --caller "<CALLER from prompt>" \
  --mode "<MODE from prompt>"
```

Use the values parsed from the incoming prompt metadata. If parsing fails, skip logging — it's not critical.

## Now Handle the Call

The caller's prompt follows. Read it, determine the mode, and respond.
