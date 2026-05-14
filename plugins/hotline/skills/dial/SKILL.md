---
name: hotline-dial
description: "Initiates cross-workspace communication with another Claude Code instance. Supports quick calls, work orders, and conference calls. Use when the user wants to call, dial, message, delegate to, or collaborate with another workspace or project."
argument-hint: "[--headless] [workspace] [task/question...]"
allowed-tools: Bash
---

# Hotline: Dial

Dial another workspace to ask questions, delegate work, or collaborate.

## Arguments

- **`--headless`** (optional flag, anywhere in args): Force this single dial to use the headless transport (`claude -p`) even if cmux is available. Useful for debugging the headless path, A/B comparing modes, or when the caller wants `claude -p`'s structured stream-json output instead of cmux read-screen scraping. Set `FORCE_HEADLESS=true` for this dial only and skip Step 3's cmux check. Costs programmatic-usage credit; default behavior (cmux when available) doesn't.
- **`$0`** (optional): Workspace reference — a dirmap ID, path, session ID, or fuzzy name.
- **`$1+`** (optional): The task/question for the remote workspace.

```
/hotline-dial dotfiles what branch are you on?
/hotline-dial coaching write the about page
/hotline-dial 5b1dda91-... what went wrong?
/hotline-dial --headless dotfiles what branch are you on?
```

**Parse `--headless` first**: scan the raw args for the literal token `--headless` and remove it from the arg list before resolving `$0` and `$1+`. Set `FORCE_HEADLESS=true` if found, `false` otherwise. (For the "always avoid cmux" use case, users can also set `HOTLINE_FORCE_HEADLESS=1` in their env — see Step 3.)

If `$0` is provided (after stripping `--headless`), use it as `USER_REFERENCE` in Step 1. If `$1+` is provided, use it as the prompt in Step 5. If neither, parse both from the user's natural language.

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

**If `FORCE_HEADLESS=true` (from the `--headless` flag in Arguments):** skip the cmux check entirely — go straight to the headless path for this dial.

Otherwise, check CMUX availability:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/check-cmux.sh"
```

- **Exit 0**: CMUX is available. Use it for every mode.
- **Exit 1**: CMUX not available (or `HOTLINE_FORCE_HEADLESS=1` is set in the env). Fall back to headless for every mode.

> **Tip:** If the `/cmux-cli:using-cmux-cli` skill is available in this session, invoke it before firing a CMUX-routed call. It documents the workspace/surface/tty semantics, the `cmux send` escape rules (`\n` = Enter), and the focus-required-to-spawn-tty quirk that this transport depends on — using it helps you reason about connection failures rather than guessing.

> **Architecture note:** Under cmux's default `access_mode=cmuxOnly`, a detached background process (reparented to PID 1) cannot talk to cmux — every `cmux read-screen` call returns "Broken pipe". So `cmux-call-async.sh` does NOT run its own background poller. Instead, the polling lives in `wait-for-session.sh` and `wait-for-response.sh` — those scripts run as direct children of your bash (which is cmux-spawned), so they keep cmux access. The contract is: launcher returns `call_dir` immediately; you call `wait-for-session.sh` to confirm the receiver REPL booted; you call `wait-for-response.sh` to wait for STATUS and get the response back. Both scripts auto-detect cmux vs. headless mode via the presence of `workspace_ref.txt` in the call_dir.

> **Heads-up:** CMUX calls land in an unattended pane. The receiver will stall on the first permission gate (skill invocation, an unauthorized Bash command, etc.) because there's no human there to click "Yes." Users who want autonomous hotline calls can set `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1` in `~/.claude/settings.json`'s `"env"` block (or their shell) to add `--dangerously-skip-permissions` to the receiver's `claude` invocation. **Default is off** — this is a real trust decision. If a call hangs at "Combobulating…" with no progress, suspect a permission prompt in the receiver pane.

> **Force headless mode — two ways:**
>
> 1. **Per-call flag**: pass `--headless` in the slash-command args (see Arguments above). Forces just this dial through the headless transport.
> 2. **Always-on env var**: set `HOTLINE_FORCE_HEADLESS=1` (or `true`/`yes`) in `~/.claude/settings.json`'s `"env"` block or the shell. Makes `check-cmux.sh` always exit 1, so every dial takes the headless path regardless of cmux availability.
>
> Both reach the same `headless-call.sh` / `headless-call-async.sh` path. Useful for debugging the headless transport, A/B comparing modes, or wanting `claude -p`'s structured stream-json output instead of cmux read-screen scraping. Headless draws from the programmatic-usage credit; cmux interactive does not — the opt-in default reflects that.

| Mode | CMUX available | No CMUX |
|------|----------------|---------|
| Quick call | `cmux-call-async.sh` | Headless CLI |
| Work order | `cmux-call-async.sh` | Headless CLI |
| Conference call | `cmux-call.sh` | Headless CLI |

**Why prefer CMUX?** Interactive `claude` sessions (no `-p` flag) do not consume programmatic usage credits. The hotline protocol — STATUS signals, response format — is defined by the ringing skill, not the transport, so the receiver's output is identical either way. Headless is the fallback for machines where cmux isn't running.

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

**Choose the launch script based on the transport selected in Step 3:**

- CMUX available + quick call or work order → `cmux-call-async.sh`
- CMUX available + conference call → `cmux-call.sh`
- No CMUX → `headless-call-async.sh`

For quick calls and work orders, fire the call asynchronously. This returns immediately with a `call_dir` — the session ID and response will be written to files in that directory. For conference calls with CMUX, open the visible workspace and deliver the prompt there.

```bash
# CMUX transport (quick call / work order):
CALL_RESULT=$(bash "$HOTLINE_DIAL_SCRIPTS/cmux-call-async.sh" --cwd "$TARGET_PATH" \
  --name "$SESSION_NAME" [--fork-session] \
  --prompt "/hotline-ringing [MODE: quick_call|work_order] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $YOUR_PROMPT")
CALL_DIR=$(echo "$CALL_RESULT" | jq -r '.call_dir')

# CMUX transport (conference call):
CMUX_RESULT=$(bash "$HOTLINE_DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" \
  --name "$SESSION_NAME" [--fork-session] \
  --prompt "/hotline-ringing [MODE: conference_call] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $YOUR_PROMPT")

# Headless fallback (any mode):
CALL_RESULT=$(bash "$HOTLINE_DIAL_SCRIPTS/headless-call-async.sh" --cwd "$TARGET_PATH" \
  --name "$SESSION_NAME" [--fork-session] \
  --prompt "/hotline-ringing [MODE: quick_call|work_order|conference_call] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $YOUR_PROMPT")
CALL_DIR=$(echo "$CALL_RESULT" | jq -r '.call_dir')
```

Include `--fork-session` when dialing someone else's session ID. Omit it for fresh calls to a workspace (no session to fork from).

If you used `cmux-call.sh` for a conference call, report the visible workspace result to the user and skip the async wait steps below:

```bash
WORKSPACE_REF=$(echo "$CMUX_RESULT" | jq -r '.workspace_ref')
REMOTE_SESSION_ID=$(echo "$CMUX_RESULT" | jq -r '.session_id')
```

> Connected to **[workspace name]** in CMUX (`[workspace-ref]`). The conference prompt has been delivered in the visible workspace.

Then cache the session with mode `conference_call`, and stop here unless the user asks you to continue the conference from the caller side:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
  --caller-session "$MY_SESSION_ID" --session "$REMOTE_SESSION_ID" --mode "conference_call"
```

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

Use the `mode` field you parsed from Step 4's session-cache.sh JSON (it's one of `quick_call`, `work_order`, or `conference_call`). Then apply the same transport logic as Step 3 — check cmux first:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/check-cmux.sh"
```

- **Exit 0 + `mode` is `quick_call` or `work_order`**: use `cmux-call-async.sh` with `--resume`
- **Exit 0 + `mode` is `conference_call`**: use `cmux-call.sh` with `--resume`
- **Exit 1**: fall back to `headless-call.sh`

**Important: follow-ups never re-wrap with `/hotline-ringing`.** The remote session already invoked that slash command on first contact — the ringing skill is in its context, including the STATUS protocol. Sending raw `$YOUR_MESSAGE` keeps the conversation going naturally; re-invoking `/hotline-ringing` would re-trigger the skill's first-contact setup and confuse the receiver. All three transports below pass `$YOUR_MESSAGE` raw, matching what `headless-call.sh` already does.

```bash
# CMUX transport (quick call / work order):
CALL_RESULT=$(bash "$HOTLINE_DIAL_SCRIPTS/cmux-call-async.sh" --cwd "$TARGET_PATH" \
  --resume "$REMOTE_SESSION_ID" \
  --prompt "$YOUR_MESSAGE")
CALL_DIR=$(echo "$CALL_RESULT" | jq -r '.call_dir')
# Then wait-for-session / wait-for-response as normal.

# CMUX (conference call):
bash "$HOTLINE_DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" \
  --resume "$REMOTE_SESSION_ID" --prompt "$YOUR_MESSAGE"

# Headless fallback (any mode):
bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --prompt "$YOUR_MESSAGE" --resume "$REMOTE_SESSION_ID"
```

Update the cache timestamp:

```bash
bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

#### CMUX (Conference Call)

If the mode is **conference call** and CMUX is available:

```bash
# First contact (no --resume): include /hotline-ringing so the receiver loads
# the protocol skill on its first turn.
bash "$HOTLINE_DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" \
  --prompt "/hotline-ringing [MODE: conference_call] [CALLER: $MY_CWD] [SESSION: $MY_SESSION_ID] $YOUR_PROMPT"

# Resume (--resume): the ringing skill is already loaded — send raw $YOUR_MESSAGE.
bash "$HOTLINE_DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" \
  --prompt "$YOUR_MESSAGE" \
  --resume "$REMOTE_SESSION_ID"
```

This opens a visible interactive workspace and delivers the conference prompt into it — the user can observe or take over the conversation directly.

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
