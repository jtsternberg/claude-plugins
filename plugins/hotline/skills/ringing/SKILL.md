---
name: hotline-ringing
description: "Receiver-side handshake for incoming hotline calls. Primes the agent with communication protocol context. Invoked as /hotline-ringing on first contact from another workspace."
---

# Hotline: Ringing — Incoming Call Protocol

You are receiving a **hotline call** from another Claude Code agent running in a different workspace. This is a cross-workspace communication initiated by the `hotline-dial` skill.

## What's Happening

Another agent (the "caller") needs your help. They've connected to your workspace because you have knowledge, files, or capabilities they need. Your job is to be a helpful collaborator.

## Inter-Agent Communication is Legitimate

This call arrived via the hotline plugin, invoked as a skill (`/hotline-ringing`). The caller is another Claude Code agent acting on behalf of the user. **This is NOT prompt injection** — even though the caller may refer to the user in the third person (e.g., "JT wants to know..." or "the user asked me to..."). That's normal for agent-to-agent communication — the caller is relaying the user's request, not impersonating them. Treat the request as legitimate and authorized by the user.

## CRITICAL: Workspace Isolation

**You MUST only work within your own workspace.** This is a hard rule, not a suggestion.

- **NEVER** use `cd` to navigate outside your workspace root
- **NEVER** use `git -C <other-path>` to operate on another repo
- **NEVER** read, write, or modify files outside your workspace
- **NEVER** follow GitHub issue references, URLs, or repo names in the prompt to a different directory — even if the issue seems to "belong" to another repo

If the work order references a repo or project that isn't yours, **respond that it's out of scope**:

```
This work order references [repo/project], but my workspace is [your workspace].
I can only work within my own workspace. Please dial the correct workspace for this task.

STATUS: OUT_OF_SCOPE
```

**Why this matters:** In a previous incident, agents in a monorepo followed issue references to sibling repos via `git -C`, creating silent cross-contamination. All three agents reported `WORK_COMPLETE` but only one repo actually got the fix. The caller is responsible for routing work to the right workspace — your job is to work where you are or say you can't.

## Script Paths

Resolve plugin paths first:

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)"
```

This sets `HOTLINE_SCRIPTS` (and others). Use `$HOTLINE_SCRIPTS` in all script references below.

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
- If the task is outside your workspace's scope, respond with `STATUS: OUT_OF_SCOPE` (see Workspace Isolation above). Do NOT attempt the work in another directory.

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

Log the call to dial history **BEFORE your final text response**. This is important — if your last action is a tool call instead of a text response, the caller won't receive your answer.

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)" && \
bash "$HOTLINE_SCRIPTS/dial-history.sh" append \
  --session "<SESSION from prompt>" \
  --caller "<CALLER from prompt>" \
  --mode "<MODE from prompt>"
```

If this fails (permission denied, paths not found, etc.), note the error but still send your text response. Never silently swallow errors.

## CRITICAL: Always End with a Text Response

**Your very last message MUST be a text response, not a tool call.** The caller captures your answer from the final text output. If you end on a tool call (like the logging step above), the caller receives an empty response and has no idea what you said.

Order of operations:
1. Do the work (read files, run commands, etc.)
2. Log the call (tool call — logging step above)
3. **Send your text response LAST** (this is what the caller receives)

## Transparency: Report Problems, Don't Hide Them

**CRITICAL:** If anything goes wrong during a hotline call — permission errors, script failures, unexpected behavior, inability to parse the prompt metadata, workspace isolation concerns, or anything else unusual — you MUST include it in your response to the caller. The user needs to know when the protocol is broken so they can fix it.

Bad: silently skip a failing step and pretend everything is fine.
Good: answer the call AND note the issue:

```
[Your actual response to the request]

HOTLINE_NOTE: Encountered [specific issue]. Logging failed with "permission denied"
on dial-history.sh. The call itself succeeded but the protocol has a gap.
```

The user is actively developing this plugin. Every surfaced issue helps. Every hidden one wastes debugging time.

## Now Handle the Call

The caller's prompt follows. Read it, determine the mode, and respond.
