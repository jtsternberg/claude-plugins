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
- **`--detached`** / **`--new-workspace`**: spawn the callee in a disconnected new workspace tab instead of a side-by-side surface. The tab auto-closes once the response is captured, so nothing is left to watch or clean up. → `--placement detached`
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
`--fresh` (ignore the cached session for this target and start a new one —
contradicts `--resume`), `--tools <list>`, `--boot-timeout <seconds>`,
`--caller-session <id>`.

Run `dial.sh --help` for the full contract.

## What it returns

Exactly one JSON object on stdout, always. Read `.status`:

| `.status` | exit | What it means | What you do |
|---|---|---|---|
| `connected` | 0 | The callee is up. `.remote_session_id`, `.workspace`, `.transport`, `.call_dir`, `.surface_ref`, `.first_contact`, `.fallbacks` describe the call. On a follow-up into a live surface, `.confirmed` and `.retried_enter` describe how the delivery landed. | Report the connection to the user, then wait for the response (below) — unless `.awaiting_response` is `false`. |
| `replay` | 2 | Identity needed a second pass. `.fingerprint` is now in the transcript. | Run **the identical command again**. Nothing else. Don't explain it to the user. |
| `needs_disambiguation` | 3 | The reference matched several workspaces; `.candidates` has them. | Ask the user which one, then re-run with `--target <their chosen path>`. |
| `error` | 1 | `.stage` (`args`/`identity`/`resolve`/`fire`/`boot`/`deliver`), `.detail` (real stderr), `.recovery` (one-line hint). | Surface `.detail` and `.recovery` to the user, and leave the retry to them. |

`deliver` is the one stage that leaves something live behind: the callee's REPL is
up and this message was never proven to land in it, so there is an open pane — empty
on first contact, mid-conversation on a follow-up. Say so — re-dialling blind can
double-deliver, because the paste may have arrived just after the confirmation
window closed.

`.confirmed` names the tier that proved a delivery: `transcript` read the nonce out
of the callee's JSONL and is definitive; `screen` inferred it from the rendered
viewport. `.retried_enter: true` means the paste's own submit key was dropped and one
corrective Enter submitted it — the delivery is good, but a run of them is worth
reporting.

`.fallbacks` lists what the wrapper worked around on its way. All of them are
already handled; mention them only if the user is debugging or the degradation
matters to them (a detached tab instead of the side-by-side surface they
expected, say).

| Entry | What happened |
|---|---|
| `cmux-cli-missing→headless` | cmux is up but cmux-cli isn't installed, so the call was re-fired headless. |
| `cmux-unavailable→headless` | No cmux at all. |
| `terminal-paste-unavailable→headless(...)` | cmux is up and answered, but does not list `terminal.paste` in `result.methods` — the verb every cmux delivery uses. **Upgrade cmux.** |
| `python3-missing→headless` | No `python3` on PATH. The control-socket helper is python3-stdlib, so cmux delivery cannot run at all. **Install python3** (nothing to do with cmux). |
| `cmux-socket-unreachable→headless(<diag>)` | The control socket could not be reached — no socket file, connection refused, timeout, or a reply that wasn't JSON. The diagnostic is the real OS error. Usually cmux is not actually running, or `$CMUX_SOCKET_PATH` points somewhere stale; `~/.local/state/cmux/last-socket-path` names the live one. **Do not upgrade cmux for this.** |
| `cmux-rpc-error→headless(rc=N <diag>)` | The socket answered but refused the preflight (`rc=1` = `ok:false`, `rc=2` = a bad call from us). The diagnostic carries its error. This one is worth reporting — it usually means the helper and cmux disagree about the protocol. |
| `surface-context→detached` | Side-by-side needs the caller's own surface context and it wouldn't resolve, so the callee landed in its own workspace tab. |
| `surface-reuse→fresh(<reason>)` | A follow-up tried to speak to the live surface and that surface refused BEFORE anything was sent (gone, mid-turn, post-interrupt, dirty input box, an RPC the socket rejected). It opened a fresh one instead; `<reason>` says which. A paste that went out and could not be confirmed is never this — it is a hard `stage: "deliver"` error, because re-delivering into a fresh `--resume` of the same session would run the work order twice. |
| `surface-reuse-skipped(no-cached-surface)` | A follow-up had no surface to reuse — first contact was headless or detached, or a previous degraded follow-up cleared a stale ref. |
| `surface-cleanup→closed(<handle>)` | A follow-up opened a new surface, so the old one held a REPL nobody would speak to again. It was proven idle and proven to be the superseded exchange, then closed. |
| `surface-cleanup-skipped(<reason>)` | The old surface was left alone. Common reasons: it is mid-turn; `parked-input` (real unsent text in its box, which closing would discard — Claude Code's own placeholder does not count once it is proven to be one, though anything unproven still reads as text and spares the surface); its identity couldn't be proven from the prior nonce; `positional-ref-unsafe` (the cached handle is a `surface:N` ref, which can name a different surface than it did — closing requires a UUID); it was already gone; or cmux refused (it will not close the last surface in a workspace). `HOTLINE_CLOSE_SUPERSEDED=0` reports `disabled`. |
| `identity→refreshed` / `identity→refresh-failed(...)` | `--refresh-identity` ran (or tried to). |
| `session-cache→fresh(<session-id>)` | `--fresh` found a cached session for this target and deliberately did not resume it; `<session-id>` is the one abandoned. The call reports `first_contact: true`, and the cache now points at the new session. |

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

**Pass the user's *exact words* to `--target`, and let the wrapper resolve them.**
"Dial the writing workspace" goes in as `the writing workspace`, not as your guess
at which repo that is. The resolver plus dirmap exist to do that matching, and they
see dirmap entries and cached identities you don't; a guess substituted here
bypasses the whole chain and dials the wrong place.

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

**Fresh phase, fresh session.** A re-dial to the same target silently resumes
the cached session. When the next dispatch must NOT inherit the previous one's
context — a reviewer for work this caller's last callee implemented, any
pipeline phase whose value is a skeptical fresh read — pass `--fresh`: it
ignores the cached session and surface, opens a brand-new session, and repoints
the cache at it (`.fallbacks` records `session-cache→fresh(<abandoned id>)`).
A plain re-dial is for continuing a conversation; `--fresh` is for starting
one in the same workspace with a new brain.

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

**A timeout is not the end of the call.** The `--timeout` budget bounds how long
*this invocation* waits, not the call, and re-running the script on the same
`CALL_DIR` resumes with a fresh budget — it re-reads the transcript (or the
screen) and sends nothing, so it can never double-queue work. Prefer that over
re-dialing when a work order is simply slower than the budget. A real remote
failure still short-circuits immediately instead of waiting again.

Exit codes that are not failures:

- **Exit 3 — the callee was reassigned.** (Not to be confused with `dial.sh`'s
  own exit 3, `needs_disambiguation` — different script, different meaning.) A
  cmux call sits in a visible surface, so the user can type into it. When they
  do, the script keeps polling for a grace window (180s, `HOTLINE_PREEMPT_GRACE`)
  and only exits 3 if no STATUS for your nonce arrives in it — a mid-call
  *redirect* of the same work order is tolerated and resolves normally. Exit 3
  therefore means they handed the session a different task, and `error.txt` names
  the preempting prompt. The surface and session are left live on purpose — the
  verdict is read off a transcript, so go check it. Report it plainly, and note the
  work you asked for may well have finished anyway: read the callee's transcript or
  look at the surface. **Do not silently re-dial.**
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
- **`HOTLINE_PASTE_BOX_TIMEOUT=<seconds>`** — how long delivery waits for the
  callee's REPL to draw its input box before refusing to paste. Defaults to
  `--boot-timeout` (itself 60 for cmux), because both are waiting for the same
  thing; set this only to decouple them. It is not a politeness timer: a payload
  delivered to a surface that has not yet exec'd `claude` goes to the **shell**,
  which would run it, so a miss here is a refusal rather than a gamble.
- **`HOTLINE_PENDING_TTL=<seconds>`** — how long a `replay` fingerprint stays
  valid in `~/.agents-hotline/pending/` (default 600). A round-trip takes
  seconds; anything older is treated as a leftover and discarded.

If the `/cmux-cli:using-cmux-cli` skill is available and a cmux-routed call
misbehaves, invoke it — it documents the workspace/surface/tty semantics this
transport depends on, which beats guessing at connection failures.

For what the dial flow itself speaks over cmux's control socket — the three RPC
methods, the snake_case-and-verify-the-echo addressing rule, `terminal.replay`'s
`anchor`, and the fact that `terminal.viewport` is a setter that would reflow the
callee's REPL — read
`${CLAUDE_PLUGIN_ROOT}/skills/dial/references/cmux-rpc.md`.

Codex: substitute the installed Hotline plugin directory for the leading path
segment above.

## Transparency: always surface problems

**Every problem reaches the user, in the same turn you hit it.** A nonzero
`.status`, an unexpected response, a permission issue, a resolution that doesn't
match what the user said — report each one with the specific error and the stage
it failed at, then say what you did about it.

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
