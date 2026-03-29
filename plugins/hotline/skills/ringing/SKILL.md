---
name: hotline:ringing
description: "Receiver-side handshake for incoming hotline calls. Primes the agent with communication protocol context. Invoked as /hotline:ringing on first contact from another workspace."
---

# Hotline: Ringing — Incoming Call Protocol

You are receiving a **hotline call** from another Claude Code agent running in a different workspace. This is a cross-workspace communication initiated by the `hotline:dial` skill.

## What's Happening

Another agent (the "caller") needs your help. They've connected to your workspace because you have knowledge, files, or capabilities they need. Your job is to be a helpful collaborator.

## Script Paths

- `PLUGIN_SCRIPTS` = the `scripts/` directory at the root of this plugin (sibling to `skills/`)

## Communication Protocol

### Call Modes

The caller's prompt will indicate the mode. Respond accordingly:

**Quick Call** — The caller needs a quick answer. Read their question, provide a concise response, and you're done. Think phone call, not meeting.

**Work Order** — The caller is delegating a task to you. Acknowledge it, do the work in your workspace, and report back with results. You have full autonomy to read files, run commands, and make changes as needed.

**Conference Call** — The caller wants to collaborate back-and-forth. Expect multiple exchanges. Each follow-up arrives via `--resume` on the same session. Work together iteratively until the task is complete.

### Response Guidelines

- Be concise. The caller is another agent, not a human — skip pleasantries.
- If you're working on a work order, provide a clear status: what you did, what the result was, whether it's complete.
- If you need clarification, ask in your response. The caller will relay to the user if needed.
- If the task is outside your workspace's scope, say so — the caller may have dialed the wrong workspace.

### Completion Signals

- **Quick call**: Your first response completes the call.
- **Work order**: End your response with "WORK COMPLETE" when the delegated task is done, or "WORK IN PROGRESS" if you need another exchange.
- **Conference call**: The caller manages the flow. Just respond to each exchange naturally.

## Logging

After handling the call, log it to the dial history:

```bash
bash "PLUGIN_SCRIPTS/dial-history.sh" append \
  --session "<session-id-from-caller>" \
  --caller "<caller-workspace-path>" \
  --mode "<quick_call|work_order|conference_call>"
```

Extract the caller info from the prompt metadata. If not available, skip logging — it's not critical.

## Now Handle the Call

The caller's prompt follows. Read it, determine the mode, and respond.
