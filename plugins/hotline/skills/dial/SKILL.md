---
name: hotline-dial
description: "Call another Claude Code workspace — quick calls, work orders, conference calls. 'Call/dial/message/delegate to <workspace or project>'."
argument-hint: "[--headless] [--detached] [--window <name|ref>] [workspace] [task/question...]"
allowed-tools: Bash, ListAgents, SendMessage
---

# Hotline: Dial

Dial another workspace to ask questions, delegate work, or collaborate.

`dial.sh` does the plumbing — identity, resolution, transport choice, session
cache, launch, boot wait — in **one command** and hands back one JSON object.
Your job is the judgment: which workspace, which mode, and what to do about the
status it returns.

## Arguments

- **`$0`** (optional): Workspace reference — a dirmap ID, path, session ID, or fuzzy name.
- **`$1+`** (optional): The task/question for the remote workspace.
- **`--headless`**: force the headless transport (`claude -p`) for this dial even when cmux is up. Debugging the headless path, A/B-ing transports, or wanting `claude -p`'s structured output. Costs programmatic-usage credit; the cmux default doesn't. → `--headless`
- **`--detached`** / **`--new-workspace`**: spawn the callee in a disconnected new workspace tab instead of a side-by-side surface (the pre-0.13 behavior). → `--placement detached`
- **`--window <name|ref>`**: land the callee as a surface in a specific cmux window (find-or-create), for grouping workers by project. A `window:<n>` ref targets that window; a bare name reuses the window holding a workspace titled `<name>`. Wins over `--detached` if both are given. → `--window <name|ref>`

```
/hotline:hotline-dial dotfiles what branch are you on?
/hotline:hotline-dial coaching write the about page
/hotline:hotline-dial 5b1dda91-... what went wrong?
/hotline:hotline-dial --headless dotfiles what branch are you on?
/hotline:hotline-dial --detached dotfiles run the full test suite
/hotline:hotline-dial --window lindris backend tests, please
```

Strip those flags out of the args before reading `$0` and `$1+`, and pass the
mapped wrapper flag shown above.

## Native fast path — Claude Code only (read first)

**Under Claude Code**, before dialing, read
`${CLAUDE_PLUGIN_ROOT}/skills/dial/references/native-messaging.md`. It decides
whether this is a lightweight message to an *already-running* session that should
go through Claude Code's native `SendMessage` — no launch, no surface, no
scraping — handles it if so, and otherwise sends you back here.

Codex: substitute the installed Hotline plugin directory for the leading path
segment above.

**Under Codex, skip it** — `ListAgents`/`SendMessage` are Claude Code only. The
flow below works from any harness.

## The one command

Write the message to a file and dial. One block, so nothing depends on shell
state carrying over:

```bash
# Codex: this path resolves under Claude Code; substitute the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PROMPT_FILE=$(mktemp /tmp/hotline-prompt-XXXXX)
cat > "$PROMPT_FILE" <<'HOTLINE_PROMPT_EOF'
<the task or question, verbatim — as many lines as you need>
HOTLINE_PROMPT_EOF
bash "$PLUGIN_ROOT/skills/dial/scripts/dial.sh" \
  --target "<the user's exact words for the target>" \
  --mode work_order \
  --prompt-file "$PROMPT_FILE"
```

The quoted heredoc delimiter means the message is copied verbatim — no quoting,
escaping, or `jq` hazards, however long or gnarly it is.

Flags: `--mode quick|work_order|conference` (required),
`--prompt-file <path>` (or `--prompt <text>` for a one-liner),
`--headless`, `--placement detached`, `--window <name|ref>`,
`--resume <session-id>` `[--no-fork]`, `--refresh-identity`,
`--tools <list>`, `--boot-timeout <seconds>`, `--caller-session <id>`.

Run `dial.sh --help` for the full contract.

## What it returns

Exactly one JSON object on stdout, always. Read `.status`:

| `.status` | exit | What it means | What you do |
|---|---|---|---|
| `connected` | 0 | The callee is up. `.remote_session_id`, `.workspace`, `.transport`, `.call_dir`, `.surface_ref`, `.first_contact`, `.fallbacks` describe the call. | Report the connection to the user, then wait for the response (below) — unless `.awaiting_response` is `false`. |
| `replay` | 2 | Identity needed a second pass. `.fingerprint` is now in the transcript. | Run **the identical command again**. Nothing else. Don't explain it to the user. |
| `needs_disambiguation` | 3 | The reference matched several workspaces; `.candidates` has them. | Ask the user which one, then re-run with `--target <their chosen path>`. |
| `error` | 1 | `.stage` (`args`/`identity`/`resolve`/`fire`/`boot`), `.detail` (real stderr), `.recovery` (one-line hint). | Surface `.detail` and `.recovery` to the user. **Never silently retry.** |

`.fallbacks` lists what the wrapper worked around on its way. All of them are
already handled; mention them only if the user is debugging or the degradation
matters to them (a detached tab instead of the side-by-side surface they
expected, say).

| Entry | What happened |
|---|---|
| `cmux-cli-missing→headless` | cmux is up but cmux-cli isn't installed, so the call was re-fired headless. |
| `cmux-unavailable→headless` | No cmux at all. |
| `surface-context→detached` | Side-by-side needs the caller's own surface context and it wouldn't resolve, so the callee landed in its own workspace tab. |
| `surface-reuse→fresh(<reason>)` | A follow-up tried to type into the live surface and that surface refused (gone, mid-turn, post-interrupt, dirty input box). It opened a fresh one instead; `<reason>` says which. |
| `surface-reuse-skipped(no-cached-surface)` | A follow-up had no surface to reuse — first contact was headless or detached, or a previous degraded follow-up cleared a stale ref. |
| `surface-cleanup→closed(<handle>)` | A follow-up opened a new surface, so the old one held a REPL nobody would speak to again. It was proven idle and proven to be the superseded exchange, then closed. |
| `surface-cleanup-skipped(<reason>)` | The old surface was left alone. Common reasons: it is mid-turn, its identity couldn't be proven from the prior nonce, it was already gone, or cmux refused (it will not close the last surface in a workspace). `HOTLINE_CLOSE_SUPERSEDED=0` reports `disabled`. |
| `identity→refreshed` / `identity→refresh-failed(...)` | `--refresh-identity` ran (or tried to). |

A follow-up that opens a second surface **always** records why. If you see a new
tab with `fallbacks:[]`, that is a bug — report it rather than explaining it
away.

`.awaiting_response` is `false` for a cmux conference call — that session is
handed to the user in a visible surface, so there is nothing to poll. Report the
surface and stop.

## Your judgment calls

The wrapper deliberately makes none of these.

**Which mode.** Ask if it's genuinely unclear: "quick question, task to hand off,
or something to work on together?"

| Mode | When | Think... |
|---|---|---|
| `quick` | Need a fast answer | "What port does your dev server run on?" |
| `work_order` | Need autonomous work done | "Run the test suite and tell me what broke." |
| `conference` | Need back-and-forth | "Let's pair on this API integration." |

**Do NOT pre-resolve the workspace.** Pass the user's *exact words* to
`--target`. "Dial the writing workspace" goes in as `the writing workspace`, not
as your guess at which repo that is. The resolver plus dirmap exist to do that
matching; substituting your own guess bypasses the whole chain and dials the
wrong place.

**Then sanity-check what came back.** If `.workspace` doesn't obviously relate to
what the user said, confirm before relaying anything:

> You asked to dial "the writing workspace." That resolved to **dotfiles**
> (`/Users/you/.dotfiles`). Right workspace?

Skip the confirmation only when the match is plainly correct ("blog" → `my-blog`).

**Fork or assist, when the user hands you a session ID.** That's someone else's
conversation. Pass `--resume <session-id>` and the wrapper **forks** it by
default, so hotline protocol noise doesn't land in their transcript. If the
user's intent is clearly to *help that session* ("continue that conversation",
"help it fix its bug"), add `--no-fork` to contribute to it directly. When in
doubt, fork.

**A stale-looking candidate list.** If `needs_disambiguation` candidates carry
empty or obviously outdated `identity` blobs, re-running with
`--refresh-identity` regenerates the resolved target's identity cache before the
call — always, not only past the cache TTL, because a within-TTL identity can
still be wrong. It costs a real headless `claude` call, tens of seconds and
programmatic credit, which is why it is opt-in rather than automatic. The payload
reports `identity_stale` either way.

## Then wait for the response

Report the connection first — the user should not wait on the callee to hear
that it's up:

> Connected to **[workspace name]** (session: `[session-id]`). Working on it —
> I'll relay the response when it's ready.

Then block on it. This is a separate step on purpose: a work order can outlast a
tool-call timeout, and you needed to speak to the user in between.

```bash
# Codex: this path resolves under Claude Code; substitute the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
CALL_DIR="<.call_dir from the dial payload>"
bash "$PLUGIN_ROOT/skills/dial/scripts/wait-for-response.sh" "$CALL_DIR" >/dev/null
RESPONSE=$(jq -r '.response' "$CALL_DIR/response.json")
printf '%s\n' "$RESPONSE"
```

Read the response **from `response.json`**, as above — not from the script's
captured stdout piped into `jq`. Under zsh (the Bash tool's shell) `echo` on
captured JSON mangles backslash escapes (`\n`, `\f`, `\u001b`, …) into raw
bytes that `jq` then rejects.

Exit codes that are not failures:

- **Exit 3 — the callee was reassigned.** (Not to be confused with `dial.sh`'s
  own exit 3, `needs_disambiguation` — different script, different meaning.) A
  cmux call sits in a visible surface,
  so the user can type into it; the moment they give it another task, your
  nonce's STATUS is never coming. The script bails immediately and writes
  `error.txt` naming the preempting prompt. Report that plainly, and note the
  work you asked for may well have finished anyway — read the callee's
  transcript or look at the surface. **Do not silently re-dial.**
- **Exit 4 — reply ready, work order not finished.** The callee emitted
  `STATUS: AWAITING_REVIEW`: it reported a checkpoint and is idle waiting on you.
  Read `.response` exactly as on exit 0 (the JSON also carries
  `"awaiting_review": true`, the durable form of the signal). The surface and
  session are left live on purpose — relay the report, then send the follow-up by
  dialing the same target again. The wrapper routes it back into that same
  surface.

Clean up when the exchange is done: `rm -rf "$CALL_DIR"`.

Follow-ups need nothing special: dial the same target again with the next
message. The wrapper finds the cached session, reuses the surface it lives in,
and sends the message raw (never re-wrapping the ringing command).

## Reporting to the user

First exchange — surface the connection details:

> Connected to **[workspace name]** (session: `[session-id]`).
> If you want to take over this conversation at any point, let me know and I'll
> give you the command to resume it in another terminal.
>
> **Their response:** [response text]

After that, just relay: > **[workspace name]:** [response text]

If the callee includes a `HOTLINE_NOTE:` in its response, always pass it on — it
means the protocol hit a snag.

## Takeover

If the user wants the conversation directly:

> Run this in another terminal:
> ```
> claude --resume [session-id]
> ```
> Let me know when you're done and I'll reconnect to get the final state.

When they return, dial the same target again with "Summarize what happened since
the caller took over."

## Environment knobs

Set these in `~/.claude/settings.json`'s `"env"` block or the shell:

- **`HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1`** — adds
  `--dangerously-skip-permissions` to the receiver's `claude`. **Off by default,
  and a real trust decision.** Without it, a call landing in an unattended pane
  stalls at the first permission gate with nobody there to click "Yes". If a call
  hangs at "Combobulating…" with no progress, suspect exactly that.
- **`HOTLINE_FORCE_HEADLESS=1`** — every dial takes the headless transport,
  regardless of cmux. Same destination as the per-call `--headless`.
- **`HOTLINE_CLAUDE_MODEL=opus`** — model override for the callee.
- **`HOTLINE_CALLER_SESSION_ID=<id>`** — supply the caller identity directly.
  Skips the fingerprint dance entirely, so `replay` never happens. This is the
  escape hatch when identity discovery fails.
- **`HOTLINE_SURFACE_READY_TIMEOUT=<seconds>`** — PTY-readiness budget for a new
  surface (default 8).
- **`HOTLINE_PENDING_TTL=<seconds>`** — how long a `replay` fingerprint stays
  valid in `~/.agents-hotline/pending/` (default 600). A round-trip takes
  seconds; anything older is treated as a leftover and discarded.

If the `/cmux-cli:using-cmux-cli` skill is available and a cmux-routed call
misbehaves, invoke it — it documents the workspace/surface/tty semantics this
transport depends on, which beats guessing at connection failures.

## Transparency: always surface problems

**Never silently work around, skip, or swallow an error.** If something goes
wrong — a nonzero `.status`, an unexpected response, a permission issue, a
resolution that doesn't match what the user said — tell the user immediately,
with the specific error and the stage it failed at.

**Bad:** "CMUX failed, falling back to headless."
**Good:** "The side-by-side surface couldn't be opened — `.detail` says
`[exact error]`. The wrapper re-routed through headless, so the call went
through, but it's in no visible pane."

The user is your partner in debugging this system. Hidden errors waste their time
and make the plugin harder to improve.

## Error recovery

**Read `${CLAUDE_PLUGIN_ROOT}/skills/dial/references/error-recovery.md`** when
`.status` is `error` and `.recovery` isn't enough — it covers the specific failure
modes per stage, and the cmux transport forensics behind a follow-up that appears
to vanish.

Codex: substitute the installed Hotline plugin directory for the leading path
segment above.
