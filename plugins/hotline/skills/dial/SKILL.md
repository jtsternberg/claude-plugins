---
name: dial
description: "Initiate cross-workspace communication with another Claude Code instance. Supports quick calls (Q&A), work orders (delegation), and conference calls (collaboration). Auto-selects transport between headless CLI and CMUX."
---

# Hotline: Dial — Cross-Workspace Communication

Place a call to another Claude Code workspace. You're the switchboard operator here — resolve the target, pick the right transport, manage the session, and relay everything back to the user. Think of yourself as a telephone operator from the 1950s, except instead of plugging cables into a switchboard, you're spawning headless CLI processes. Progress!

## Script Paths

- `PLUGIN_SCRIPTS` = the `scripts/` directory at the root of this plugin (sibling to `skills/`)
- `DIAL_SCRIPTS` = `skills/dial/scripts/` within this plugin
- `PICKUP_SCRIPTS` = `skills/pickup/scripts/` within this plugin

## Prerequisites: Know Thyself

Before you can call anyone else, you need to know your own session ID. Run:

```bash
bash "PLUGIN_SCRIPTS/session-fingerprint.sh"
```

- **Exit 0** (stdout = session ID): Store as `MY_SESSION_ID`. You're good to go.
- **Exit 1** (stderr = fingerprint): Your session ID isn't cached yet. Run discovery in a **separate tool call** (the transcript file must be written first):

```bash
bash "PLUGIN_SCRIPTS/session-discover.sh" <fingerprint>
```

This returns the session ID on stdout. Store it as `MY_SESSION_ID`.

## Decision Tree

Follow these steps in order. No freelancing — the protocol matters.

### Step 1: Resolve the Target Workspace

Figure out who the user wants to call. Run:

```bash
bash "DIAL_SCRIPTS/resolve-workspace.sh" "<reference>" --caller-session "$MY_SESSION_ID"
```

Where `<reference>` is whatever the user said — a project name, path, description, etc.

- **Exit 0**: Target resolved. Parse the JSON output for `path` and `name`.
- **Exit 1**: Check stderr.
  - If it contains JSON with `candidates`: present the list to the user and ask them to pick one.
  - Otherwise: it's an error. Report it and stop.

#### Stale Identity Recovery

If resolution fails or returns stale results, check whether the target's identity cache needs refreshing:

```bash
bash "PICKUP_SCRIPTS/identity-cache.sh" is-stale --cwd "$TARGET_PATH"
```

If exit 0 (stale): run a quick headless call to populate it:

```bash
bash "DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --prompt "/hotline:pickup"
```

Then retry resolution from the top.

### Step 2: Determine the Call Mode

Ask the user (or infer from context) what kind of call this is:

| Mode | When to Use | Think... |
|------|-------------|----------|
| **Quick call** | Need a fast answer from the other workspace | "Hey, what port does your dev server run on?" |
| **Work order** | Need the other workspace to do something autonomously | "Run the test suite and tell me what broke." |
| **Conference call** | Need back-and-forth collaboration | "Let's pair on this API integration." |

If the user's intent is ambiguous, ask. One question: "Is this a quick question, a task you want to hand off, or something you want to work on together?"

### Step 3: Select Transport

This is automatic — never ask the user about transport. They don't care how the sausage gets made.

| Mode | Transport |
|------|-----------|
| Quick call | Headless CLI |
| Work order | Headless CLI |
| Conference call (short, ~2-3 exchanges) | Headless CLI |
| Conference call (deep collaboration) | CMUX if available, else headless |

For conference calls that look like they'll go deep, check CMUX availability:

```bash
bash "DIAL_SCRIPTS/check-cmux.sh"
```

- **Exit 0**: CMUX is available. Use it.
- **Exit 1**: CMUX not available. Fall back to headless.

### Step 4: Check for Existing Session

See if there's already an active session with this workspace:

```bash
bash "DIAL_SCRIPTS/session-cache.sh" get "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

- **Exit 0**: Active session found. Parse the JSON for `session_id` and `mode`. Reuse it.
- **Exit 1**: No existing session. You'll create one in Step 5.

### Step 5: Execute the Call

#### First Contact (No Existing Session)

Place the call:

```bash
bash "DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --prompt "/hotline:ringing [MODE: quick_call|work_order|conference_call] $YOUR_PROMPT"
```

Parse the JSON response. Extract `session_id` and `response`.

Cache the session for future use:

```bash
bash "DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
  --caller-session "$MY_SESSION_ID" --session "$REMOTE_SESSION_ID" --mode "$MODE"
```

#### Follow-Up (Existing Session)

Continue the conversation:

```bash
bash "DIAL_SCRIPTS/headless-call.sh" --prompt "$YOUR_MESSAGE" --resume "$REMOTE_SESSION_ID"
```

Update the cache timestamp:

```bash
bash "DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

#### CMUX (Conference Call Only)

If CMUX was selected in Step 3:

```bash
bash "DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" [--resume "$REMOTE_SESSION_ID"]
```

Pass `--resume` only if reusing an existing session from Step 4.

## Reporting to the User

### First Response

Always surface the connection details on the first exchange:

> Connected to **[workspace name]** (session: `[session-id]`).
> If you want to take over this conversation at any point, let me know and I'll give you the command to resume it in another terminal.
>
> **Their response:** [response text]

### Subsequent Exchanges

Just relay the response — no need to repeat the connection boilerplate:

> **[workspace name]:** [response text]

## Adaptive Escalation

For conference calls running in headless mode: if you've done ~3+ round trips and CMUX is available, it's time to upgrade. Open a CMUX workspace:

```bash
bash "DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" --resume "$REMOTE_SESSION_ID"
```

Announce the upgrade:

> This conversation is getting lengthy. I've opened a CMUX window so you can continue it with a proper terminal session.

## Takeover

If the user asks to take over the conversation directly, give them the escape hatch:

> Run this in another terminal:
> ```
> claude --resume [session-id]
> ```
> Let me know when you're done and I'll reconnect to get the final state.

When they return, resume the session yourself to pick up any final state:

```bash
bash "DIAL_SCRIPTS/headless-call.sh" --prompt "Summarize what happened since the caller took over." --resume "$REMOTE_SESSION_ID"
```
