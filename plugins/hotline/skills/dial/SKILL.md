---
name: hotline-dial
description: "Initiates cross-workspace communication with another Claude Code instance. Supports quick calls, work orders, and conference calls. Use when the user wants to call, dial, message, delegate to, or collaborate with another workspace or project."
argument-hint: "[workspace] [task/question...]"
allowed-tools: Bash
---

# Hotline: Dial

Dial another workspace to ask questions, delegate work, or collaborate.

## Arguments

- **`$0`** (optional): Workspace reference — a dirmap ID, path, session ID, or fuzzy name.
- **`$1+`** (optional): The task/question for the remote workspace.

```
/hotline-dial dotfiles what branch are you on?
/hotline-dial coaching write the about page
/hotline-dial 5b1dda91-... what went wrong?
```

If `$0` is provided, use it as `USER_REFERENCE` in Step 1. If `$1+` is provided, use it as the prompt in Step 5. If neither, parse both from the user's natural language.

## Script Paths

!`bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh`

The above sets `HOTLINE_SCRIPTS`, `HOTLINE_DIAL_SCRIPTS`, and `HOTLINE_PICKUP_SCRIPTS`.

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

If the user gave you a specific session ID to dial (e.g., "dial session abc123"), that's someone else's session. **Fork by default** (`--fork-session` flag) to avoid cluttering their conversation with hotline protocol noise.

**Override:** If the user's intent is clearly to contribute to or help that session (e.g., "help that session fix its bug," "continue that conversation"), don't fork — they want to add to the existing session. When in doubt, fork.

**CRITICAL: When dialing by session ID, the `--cwd` MUST come from Step 1's resolve output** (which reverse-looks up the session ID to find its workspace via transcript files). Do NOT use your own workspace as `--cwd` — the target session lives in a different directory, and using the wrong `--cwd` causes `--fork-session` to silently fail with empty output.

### Step 5: Execute the Call

#### First Contact (No Existing Session)

Construct a session name for the `/resume` picker. Format: `hotline: <caller-dir> → <target-dir> (<mode>)` using just the directory basenames (not full paths). Example: `hotline: marketing → blog (quick_call)`.

Fire the call asynchronously. This returns immediately with a `call_dir` — the session ID and response will be written to files in that directory:

```bash
CALL_RESULT=$(bash "$HOTLINE_DIAL_SCRIPTS/headless-call-async.sh" --cwd "$TARGET_PATH" \
  --name "$SESSION_NAME" [--fork-session] \
  --prompt "/hotline-ringing [MODE: quick_call|work_order|conference_call] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $YOUR_PROMPT")
CALL_DIR=$(echo "$CALL_RESULT" | jq -r '.call_dir')
```

Include `--fork-session` when dialing someone else's session ID. Omit it for fresh calls to a workspace (no session to fork from).

**Wait for the session ID** (returns quickly once the remote agent starts):

```bash
REMOTE_SESSION_ID=$(bash "$HOTLINE_DIAL_SCRIPTS/wait-for-session.sh" "$CALL_DIR")
```

**Report the session ID to the user right away** — don't wait for the full response:

> Connected to **[workspace name]** (session: `[session-id]`). Working on it — I'll relay the response when it's ready.

**Then wait for the response:**

```bash
bash "$HOTLINE_DIAL_SCRIPTS/wait-for-response.sh" "$CALL_DIR" >/dev/null
REMOTE_SESSION_ID=$(jq -r '.session_id' "$CALL_DIR/response.json")
RESPONSE=$(jq -r '.response' "$CALL_DIR/response.json")
```

`wait-for-response.sh` stdout is guaranteed to be valid, compact JSON on exit 0 — or a non-zero exit with a clear error on stderr. Callers do not need to re-validate.

**⚠️ Do not do this** — under zsh (the default shell on macOS, and the shell Claude Code's Bash tool runs in) the `echo`-pipe pattern corrupts any JSON with backslash escapes (`\n`, `\f`, `\u001b`, ...):

```bash
# WRONG — zsh's echo interprets \f and \u001b in the captured JSON,
#         producing malformed bytes jq then rejects with a parse error.
RESPONSE_JSON=$(bash "$HOTLINE_DIAL_SCRIPTS/wait-for-response.sh" "$CALL_DIR")
echo "$RESPONSE_JSON" | jq -r '.response'
```

Read from the file (preferred, shown above) or use a here-string: `jq -r '.response' <<<"$RESPONSE_JSON"`. If a caller ever sees a `parse error: Invalid string: control characters from U+0000 through U+001F` on `wait-for-response.sh` output, that's a hotline bug — file it via `bd` under the hotline plugin with the stream.jsonl and response.json captured from the call_dir.

Cache the session:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
  --caller-session "$MY_SESSION_ID" --session "$REMOTE_SESSION_ID" --mode "$MODE"
```

Clean up: `rm -rf "$CALL_DIR"`

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
