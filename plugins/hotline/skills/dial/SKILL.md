---
name: hotline-dial
description: "Initiate cross-workspace communication with another Claude Code instance. Supports quick calls (Q&A), work orders (delegation), and conference calls (collaboration). Auto-selects transport between headless CLI and CMUX."
---

# Hotline: Dial — Cross-Workspace Communication

Place a call to another Claude Code workspace. You're the switchboard operator here — resolve the target, pick the right transport, manage the session, and relay everything back to the user. Think of yourself as a telephone operator from the 1950s, except instead of plugging cables into a switchboard, you're spawning headless CLI processes. Progress!

## Script Paths

Before running any scripts, resolve the plugin paths. Run this once at the start:

```bash
eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)"
```

This sets:
- `HOTLINE_SCRIPTS` — shared scripts (session fingerprint, dirmap fallback, dial history)
- `HOTLINE_DIAL_SCRIPTS` — dial-specific scripts (resolve, cache, transport)
- `HOTLINE_PICKUP_SCRIPTS` — pickup scripts (identity cache)

## Prerequisites: Know Thyself

Before you can call anyone else, you need to know your own session ID. Run:

```bash
bash "$HOTLINE_SCRIPTS/session-init.sh"
```

Parse the JSON output:

- `{"status": "cached", "session_id": "..."}` — Store as `MY_SESSION_ID`. Done.
- `{"status": "planted", "fingerprint": "..."}` — The transcript needs to be written first. In a **separate tool call**, run:

```bash
bash "$HOTLINE_SCRIPTS/session-init.sh" discover "<fingerprint>"
```

This returns `{"status": "discovered", "session_id": "..."}`. Store as `MY_SESSION_ID`.

- `{"status": "error", "message": "..."}` — Discovery failed. Offer the user two options:

  1. **Continue without session ID (not recommended):** You can still dial, but session caching won't work — multiple Claude instances in the same directory could collide, and you won't be able to resume calls cleanly. If the user is OK with that, set `MY_SESSION_ID` to a generated UUID and proceed.

  2. **Manual session ID:** The user can Ctrl+C, note the session ID displayed on exit, then resume with `claude --resume <id>` and pass you the session ID. This almost never happens — it's a fallback for the fallback.

## Decision Tree

Follow these steps in order. No freelancing — the protocol matters.

### Step 1: Resolve the Target Workspace

**CRITICAL: DO NOT pre-resolve the workspace.** When the user says "dial the writing workspace," you MUST pass their exact words to the resolver. Do NOT substitute your own guess (e.g., turning "writing workspace" into "dotfiles"). The resolver + dirmap handle matching — that is their job, not yours. If you pre-resolve, you bypass the entire resolution chain and will dial the wrong workspace.

Store the user's exact reference for later comparison:

```
USER_REFERENCE="<the user's exact words for the target>"
```

Then resolve:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/resolve-workspace.sh" "$USER_REFERENCE" --caller-session "$MY_SESSION_ID"
```

- **Exit 0**: Target resolved. The resolved path is on stdout.
- **Exit 1**: Check stderr.
  - If it contains JSON with `candidates`: present the list to the user and ask them to pick one.
  - Otherwise: it's an error. Report it and stop.

#### Sanity Check: Does the Resolution Make Sense?

After resolution, compare what the user asked for against what was resolved. If the resolved workspace name doesn't obviously relate to the user's reference, **confirm with the user before proceeding**:

> You asked to dial "the writing workspace." The closest match I found is **dotfiles** (`/Users/you/.dotfiles`). Is that the right workspace?

Only skip this confirmation when the match is clearly correct (e.g., user said "blog" and it resolved to "my-blog").

#### Stale Identity Recovery

If resolution fails or returns stale results, check whether the target's identity cache needs refreshing:

```bash
bash "$HOTLINE_PICKUP_SCRIPTS/identity-cache.sh" is-stale --cwd "$TARGET_PATH"
```

If exit 0 (stale): run a quick headless call to populate it:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --prompt "/hotline-pickup"
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
bash "$HOTLINE_DIAL_SCRIPTS/check-cmux.sh"
```

- **Exit 0**: CMUX is available. Use it.
- **Exit 1**: CMUX not available. Fall back to headless.

### Step 4: Check for Existing Session and Determine Fork Behavior

See if there's already an active session with this workspace:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" get "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

- **Exit 0**: Active session found. Parse the JSON for `session_id` and `mode`. Reuse it. **Don't fork** — this is our own session from a prior hotline call, and we want context continuity.
- **Exit 1**: No existing session. Will create one in Step 5.

**Fork behavior when the user provided a session ID directly** (not from our cache):

If the user gave you a specific session ID to dial (e.g., "dial session abc123"), that's someone else's session. **Fork by default** (`--fork` flag) to avoid cluttering their conversation with hotline protocol noise.

**Override:** If the user's intent is clearly to contribute to or help that session (e.g., "help that session fix its bug," "continue that conversation"), don't fork — they want to add to the existing session. When in doubt, fork.

### Step 5: Execute the Call

#### First Contact (No Existing Session)

Construct a session name for the `/resume` picker. Format: `hotline: <caller-dir> → <target-dir> (<mode>)` using just the directory basenames (not full paths). Example: `hotline: marketing → blog (quick_call)`.

Place the call. If the user provided a session ID directly (and you determined in Step 4 that forking is appropriate), add `--fork`:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --name "$SESSION_NAME" [--fork] \
  --prompt "/hotline-ringing [MODE: quick_call|work_order|conference_call] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $YOUR_PROMPT"
```

Include `--fork` when dialing someone else's session ID. Omit it for fresh calls to a workspace (no session to fork from).

Parse the JSON response. Extract `session_id` and `response`.

Cache the session for future use:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
  --caller-session "$MY_SESSION_ID" --session "$REMOTE_SESSION_ID" --mode "$MODE"
```

#### Follow-Up (Existing Session from Our Cache)

Continue the conversation — no fork, this is our own session:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" --prompt "$YOUR_MESSAGE" --resume "$REMOTE_SESSION_ID"
```

Update the cache timestamp:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

#### CMUX (Conference Call Only)

If CMUX was selected in Step 3:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" [--resume "$REMOTE_SESSION_ID"]
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
bash "$HOTLINE_DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" --resume "$REMOTE_SESSION_ID"
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
bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --prompt "Summarize what happened since the caller took over." --resume "$REMOTE_SESSION_ID"
```

## Transparency: Always Surface Problems to the User

**CRITICAL:** Never silently work around, skip, or swallow errors. If something goes wrong at any step — script failures, unexpected responses, permission issues, resolution mismatches, protocol problems — **tell the user immediately.** Include the specific error, what step failed, and what you know about why.

The user is your partner in debugging this system. They can help you solve problems you can't solve alone. Hiding errors wastes their time and makes the plugin harder to improve.

**Bad:** "CMUX failed, falling back to headless." (What failed? Why? Can we fix it?)
**Good:** "CMUX workspace creation failed — `cmux new-workspace` returned: `[exact error]`. Falling back to headless. This might be a bug in cmux-call.sh."

**Bad:** Silently resolving "writing workspace" to "dotfiles" without checking.
**Good:** "I resolved 'writing workspace' to 'dotfiles' — does that sound right, or did you mean a different workspace?"

If the receiving agent (Agent B) includes a `HOTLINE_NOTE:` in its response, always surface that to the user — it means the protocol hit a snag.

## Error Recovery

If anything goes wrong at any step, consult `references/error-recovery.md` for specific failure modes and recovery steps.
