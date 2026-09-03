---
name: hotline-dial
description: "Call another Claude Code workspace — quick calls, work orders, conference calls. 'Call/dial/message/delegate to <workspace or project>'."
argument-hint: "[--headless] [--herdr] [--remote <ssh-target>] [--detached] [--window <name|ref>] [workspace] [task/question...]"
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
- **`--herdr`**: host the callee as a **herdr agent** instead of a cmux surface — a persistent pane owned by the herdr server, so the callee **survives a detach, a closed lid, or a dropped SSH session**. That is the reason to ask for it: a long work order you do not want tied to the life of a window. Requires herdr running, here or — with `--remote` below — on another box. Takes any mode, including `conference`, and either the side or detached placement (herdr splits a pane off yours for both). → `--transport herdr`
- **`--remote <ssh-target>`**: run the callee **on another box** — herdr splits a pane and starts claude *there*, and hotline reads its answer back over ssh. For work that belongs on that machine: its checkout, its GPU, its network. It **selects herdr on its own** (nothing else can host anywhere but here) and is detached by nature, so `--remote <target>` alone is the whole invocation. Needs a non-interactive ssh hop plus herdr *and* claude on that box; if any of that is missing the dial is an **error**, never a quiet local call. → `--remote <ssh-target>`

```
/hotline:hotline-dial dotfiles what branch are you on?
/hotline:hotline-dial coaching write the about page
/hotline:hotline-dial 5b1dda91-... what went wrong?
/hotline:hotline-dial --headless dotfiles what branch are you on?
/hotline:hotline-dial --detached dotfiles run the full test suite
/hotline:hotline-dial --window lindris backend tests, please
/hotline:hotline-dial --herdr dotfiles run the 40-minute migration
/hotline:hotline-dial --remote jt@buildbox lindris run the integration suite
```

Strip those flags out of the args before reading `$0` and `$1+`, and pass the
mapped wrapper flag shown above.

## Native fast path — Claude Code only

Launching is the default. Claude Code can also hand a message straight to a session
that is *already running* (`ListAgents` + `SendMessage`) — that is the exception, and
it needs positive evidence in the user's own words. Take it **only when both hold**:

1. **The user names a running session, not a workspace.** "My other session", "the
   session/terminal/tab that's working on X", a name they were shown from `ListAgents`
   or set with `/rename`, or a reply to a `<cross-session-message>` you received. A
   workspace, project, or folder name is not a session reference: "dial/call
   <workspace>" always launches. `ListAgents` will usually show live sessions in that
   folder — hotline's own callees live there — so a live match on a project slug is
   expected noise, not a signal.
2. **The message is answerable from where that session already sits** — a fact, a
   nudge, a quick question about its own state. Anything it must go read or fetch (a
   URL, an issue, a file) or do is a work order: launch it, so it lands on a surface
   and the switchboard.

The user's words decide this, not a probe: do not run `ListAgents` to find out whether
native applies. In doubt, launch.

When both hold, read `${CLAUDE_PLUGIN_ROOT}/skills/dial/references/native-messaging.md`
for the mechanics; it sends you back here if the live sessions don't match.

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
`--headless`, `--transport cmux|herdr|headless`, `--remote <ssh-target>`,
`--placement side|detached`,
`--window <name|ref>`, `--resume <session-id>` `[--no-fork]`,
`--refresh-identity`,
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
| `error` | 1 | `.stage` (`args`/`identity`/`resolve`/`transport`/`fire`/`boot`/`deliver`), `.detail` (real stderr), `.recovery` (one-line hint). | Surface `.detail` and `.recovery` to the user, and leave the retry to them. |

`deliver` is the one stage that leaves something live behind: the callee's REPL is
up and this message was never proven to land in it, so there is an open pane — empty
on first contact, mid-conversation on a follow-up. Say so — re-dialling blind can
double-deliver, because the paste may have arrived just after the confirmation
window closed. The exception announces itself in `.recovery`: a trust-dialog refusal
is made before anything is pasted, so its recovery says nothing was delivered and
re-dialing is safe — the TRUST DIALOG entries in
`${CLAUDE_PLUGIN_ROOT}/skills/dial/references/error-recovery.md`, under § CMUX
Failures for a cmux call and § herdr Failures for a herdr one.

Codex: substitute the installed Hotline plugin directory for the leading path
segment above.

`.confirmed` names the tier that proved a delivery: `transcript` read the nonce out
of the callee's JSONL and is definitive; `screen` inferred it from the rendered
viewport. `.retried_enter: true` means the paste's own submit key was dropped and one
corrective Enter submitted it — the delivery is good, but a run of them is worth
reporting.

`transport` means the backend the caller asked for is not usable here — herdr is not
installed, or no herdr server answered. **It is never a degradation**: an explicit
`--transport herdr` is an ask for a callee that survives a disconnect, and quietly
handing back a cmux surface instead would be a lie the user only discovers hours later. Pass
`.detail` and `.recovery` through as-is; both name the fix.

## The herdr transport (opt-in, local or remote)

`--transport herdr` hosts the callee as a **named herdr agent** in a persistent
pane, split off the caller's own pane. What you get for it is durability: the herdr
server owns the PTY, so the callee outlives a detach, a closed lid and a dropped
SSH session — and it is still a pane next to yours, which is why side placement and
conference mode both work here.

| Combination | Answer |
|---|---|
| `--transport herdr`, any mode, `--placement side` or `--detached` | supported — first contact and follow-ups |
| `--placement window` / `--window <ref>` | refused — hotline creates no herdr workspaces or tabs, so there is no window to place a callee in. Not a phase gate; a feature nobody has built |
| `--resume <someone-else's-session-id>` | refused — herdr hosts a callee it *starts*, with a session id hotline presets so the transcript is readable; `claude --resume` cannot take that preset. Continuing a session **you** dialed needs no flag (see below) |
| `--remote <ssh-target>` | supported — see below. Implies `--transport herdr` and, unless a placement was typed, `--detached` |
| `--remote` with `--transport cmux`/`headless` | refused — remote hosting is herdr-only; a cmux surface lives in this machine's window server and `claude -p` is a local process |

**Follow-ups need no flag and no surface machinery.** Re-dial the same target with
`--transport herdr --detached` and the cached agent is re-targeted by name
(`herdr agent prompt`), so the conversation continues in the same session and the
same transcript. The named agent *is* the session, so there is no host to resolve,
no input box to clear, and nothing superseded to close.

**A cached agent that has exited** falls back to a fresh callee, reported in
`.fallbacks`, and that callee has **none of the prior conversation** — herdr cannot
re-host an existing claude session. The fallback entry says so outright; relay it if
the answer depends on prior context.

**A cached agent that is `blocked` on input fails the dial instead** (`stage:
transport`), and that difference is deliberate. A follow-up submitted into a
permission gate would answer the gate rather than start a turn — but that agent is
still live and still holds the only copy of the conversation, so answering with a
fresh callee would leave it running and unreachable through hotline. Nothing is
submitted and nothing is started: tell the user to clear it (`herdr agent attach
<name>` shows what it is asking), then re-dial exactly as before and the same agent
is re-targeted with its context intact.

**`--mode conference` hands the pane to the user.** The callee is started beside
the caller exactly as a work order is, the prompt is delivered the same way, and
then — only then, and only for a conference — hotline **focuses** the callee's pane
(`herdr agent focus <name>`). `.awaiting_response` comes back `false`: the session
is the user's to talk to, so there is nothing to poll. Report the pane and stop.
Every other herdr dial splits with `--no-focus` and never moves the user.

(`herdr session attach <name>` is a different thing and not the conference story:
it attaches a *detached* herdr session from another terminal.)

cmux stays the default, and an ambient signal never selects herdr: being inside a
herdr pane (`HERDR_ENV=1`) only makes the option *available*. Two things select it
— `--transport herdr` per call, and the opt-in `HOTLINE_TRANSPORT_AUTO=1` (see the
environment section), which lets `HERDR_ENV=1` decide for a dial that names no
transport.

`--headless` and `--transport herdr` together are refused — two explicit,
incompatible asks, and dropping either one silently would discard a flag the user
typed on purpose. An ambient `HOTLINE_FORCE_HEADLESS=1` is different: a per-call
`--transport` outranks an environment default, and `.transport` reports what ran.

Two consequences worth telling the user about:

- **`.surface_ref` holds the herdr AGENT NAME** for a herdr call, not a cmux
  surface handle. It is the durable handle: `herdr agent get <name>` for its state,
  `herdr agent attach <name>` to watch it.
- **The pane is left open after the response.** Outliving the call is the point, so
  hotline does not close it the way it closes a detached cmux tab. When the user is
  done: `herdr pane close $(cat <call_dir>/herdr_pane.txt)` — or, for a remote call,
  `ssh <.remote_target> herdr pane close <.remote_pane>`, both of which the emitted
  JSON carries for exactly this reason.

### `--remote <ssh-target>` — the callee on another box

Same transport, one ssh hop. herdr's own `--remote` only attaches its TUI and
rejects every subcommand, so hotline drives the **ordinary herdr CLI on that box**
over ssh — `ssh <target> herdr pane split …`, `agent start`, `agent prompt`,
`agent wait` — against that box's own local server. Every verb, every refusal and
every proof tier is the local arm's; what changes is which machine answers.

What the dial needs, and what it says when it is missing (all `stage: transport`,
all errors rather than degradations — there is no local substitute for "run this
over there"):

| Missing | The error names |
|---|---|
| the ssh hop | that the target could not be reached **non-interactively**, and that hotline never answers a password or a browser check |
| herdr on that box | the target, not the caller's own install |
| a herdr server there | that nothing answered *there* — being inside a herdr pane yourself proves nothing about it |
| a pane to split there | `HOTLINE_HERDR_REMOTE_PANE`, the remote-only override |
| `claude` on that box's **non-login** PATH | `ssh <target> command -v claude`, because a claude under `~/.local/bin` may resolve for a human and not for an ssh command |

Three things worth telling the user:

- **The answer is read from the remote transcript.** `~/.claude/projects/<encoded
  realpath>/<session>.jsonl` on *that* box — both halves asked of it, never assumed
  from here — fetched over the same hop and parsed by the unchanged extractor. So
  `.response`, `AWAITING_REVIEW`, preemption and the exit codes are identical to a
  local call.
- **The work order never rides the ssh command line.** It is submitted through a
  fixed remote command that reads stdin, so it stays out of the local `ps` and its
  only argv exposure is the sub-second one on the box actually running it.
- **Tailscale SSH may want a browser check.** Its notice is filtered out of every
  read, but when the check period has lapsed a non-interactive hop cannot complete
  and the dial fails naming the `login.tailscale.com` URL. The fix is for the user
  to run `ssh <target> true` themselves once.

Follow-ups work exactly as the local ones do — re-dial the same target with the same
`--remote`, and the cached agent on that box is re-targeted by name. **Re-dialing
that workspace WITHOUT `--remote` starts a fresh callee** rather than talking to the
remote one, reported in `.fallbacks` as a host mismatch: the cache records which box
a handle belongs to, and an agent name from another machine cannot be re-addressed
from here.

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
| `transport-auto→cmux(<reason>)` | `HOTLINE_TRANSPORT_AUTO=1` was set inside a herdr pane, but the herdr preflight failed — so the dial went to the cmux default instead. A degrade, not an error: nothing explicit was asked for. `<reason>` is the preflight's own (no server, no splittable pane, herdr not installed). |
| `herdr-conference-focus-failed(<agent>: <reason>)` | A herdr conference connected and the callee has the prompt, but `herdr agent focus` refused — so the user's focus did not move. Tell them which pane to go to (`herdr agent attach <agent>`). |
| `identity→refreshed` / `identity→refresh-failed(...)` | `--refresh-identity` ran (or tried to). |
| `session-cache→fresh(<session-id>)` | `--fresh` found a cached session for this target and deliberately did not resume it; `<session-id>` is the one abandoned. The call reports `first_contact: true`, and the cache now points at the new session. |

A follow-up that opens a second surface **always** records why. If you see a new
tab with `fallbacks:[]`, that is a bug — report it rather than explaining it
away.

`.awaiting_response` is `false` for a conference call **on first contact**, on either
transport — that session is handed to the user in a visible surface (cmux) or a
focused pane (herdr), so there is nothing to poll. Report it and stop.

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
- **Exit 5 — the callee is waiting on a human** (herdr calls only). herdr reported
  its lifecycle as `blocked` with no STATUS for your nonce: it is sitting on a
  permission gate or asking a question, so more time cannot help. `error.txt` says
  what to look at; `herdr agent attach <name>` shows the actual prompt (prefixed with
  `ssh <target>` for a `--remote` call, which the message itself does). Tell the user
  what is needed, and once it is cleared re-run the wait on the same `CALL_DIR` — it
  resumes with a fresh budget and reads the answer. (Unattended callees avoid the
  permission case by dialing with `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1` — a real
  trust decision.)

Clean up when the exchange is done: `rm -rf "$CALL_DIR"`.

Follow-ups need nothing special: dial the same target again with the next
message. The wrapper finds the cached session, re-addresses the host it lives in —
a cmux surface, or a herdr agent by name — and sends the message raw (never
re-wrapping the ringing command).

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
- **`HOTLINE_CLAUDE_APPEND_SYSTEM_PROMPT_FILE=<path>`** — appends the file's
  contents to the callee's system prompt (`claude --append-system-prompt-file`),
  for steering the callee's behavior — e.g. an "Opus 5" operating prompt. Passed
  as a file, never inline, so the prompt never rides an argv where `ps` could
  read it; the file must stay readable until the callee boots. Applies at first
  contact only (a session's system prompt is set once, at birth); follow-ups
  reuse that session. A missing/unreadable path fails the dial up front.
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

One selects the transport, and it is the only variable that does:

- **`HOTLINE_TRANSPORT_AUTO=1`** — opt in to herdr being chosen without
  `--transport`. It selects herdr only when **all** of these hold: the value is
  exactly `1`; the dial named no `--transport`; it is not headless (`--headless` /
  `HOTLINE_FORCE_HEADLESS`); the caller is inside a herdr pane (`HERDR_ENV=1`); and
  the herdr preflight passes. A failed preflight is a **degrade** to the cmux
  default with a `transport-auto→cmux(...)` entry in `.fallbacks`, not an error —
  nothing explicit was asked for. `.transport` always reports what actually ran.

The rest are herdr-only and select nothing — `--transport herdr` or the opt-in
above still does that:

- **`HOTLINE_HERDR_PANE=<pane-id>`** — the pane hotline splits to host the callee.
  Defaults to the caller's own `$HERDR_PANE_ID`, then to the first pane herdr
  reports. Name one when the automatic choice lands somewhere awkward.
- **`HOTLINE_HERDR_SPLIT_DIRECTION=right|down`** — which way that split goes
  (default `right`).
- **`HOTLINE_HERDR_PANE_SETTLE=<seconds>`** — pause before starting the agent in a
  freshly split pane (default 1). `agent start` requires the pane to be at its shell
  prompt, and starting too early fails `agent_pane_busy` (which is then retried).
- **`HOTLINE_HERDR_FIRST_SETTLE=<seconds>`** — pause between `agent start`'s
  readiness claim and the FIRST delivery into that agent (default 1). `agent start`
  reports the REPL interactive-ready once, at return, and under load that claim can
  lead actual keystroke acceptance; this is the wall clock a re-probe cannot buy.
- **`HOTLINE_HERDR_READY_TRIES=<n>`** — how many times first-contact delivery
  re-reads `agent get` waiting for `interactive_ready` and a non-`blocked` state
  (default 20, at `HOTLINE_PASTE_CONFIRM_SLEEP`'s cadence). Exhausting it refuses the
  delivery with `sent:false`, so nothing was submitted and a re-dial is safe.
- **`HOTLINE_HERDR_FIRST_CONFIRM_TRIES=<n>`** — the transcript-confirmation budget
  for a FIRST delivery (default 40, four times the follow-up budget). First contact
  waits on the callee's transcript being *created*, not appended, so the follow-up
  budget reported landed payloads as unconfirmed under load.
- **`HOTLINE_HERDR_BLOCKED_SETTLE=<seconds>`** — pause between the two reads that
  confirm a follow-up's cached agent is really `blocked` (default 1). That state
  fails the dial, so a blink must not be acted on.
- **`HOTLINE_HERDR_WAIT_SLICE_MS=<ms>`** — how long one `herdr agent wait` blocks
  before the response wait re-reads the transcript (default 30000).
- **`HOTLINE_HERDR_KEEP_FAILED_PANE=1`** — keep the pane after a failed launch. Off
  by default (a failed dial should leak nothing); on, the pane's scrollback is the
  only evidence of a launch that died before the agent was detected.

These four apply to a **`--remote`** dial only:

- **`HOTLINE_HERDR_REMOTE_PANE=<pane-id>`** — the pane on the REMOTE box that
  hotline splits, defaulting to the first pane that box's herdr reports. Named
  separately from `HOTLINE_HERDR_PANE` on purpose: a pane id means nothing on
  another machine, so a habitual local override must never be applied to one.
  `$HERDR_PANE_ID` (the caller's own pane) is ignored for a remote dial.
- **`HOTLINE_REMOTE_SSH_TIMEOUT=<seconds>`** — the floor on each ssh hop's budget
  (default 60). A hop carrying a blocking herdr verb gets the herdr `--timeout` plus
  30s instead, so `agent start` is not killed out from under a working launch.
  Every hop is time-boxed: a Tailscale check period that has lapsed would otherwise
  block a `BatchMode` hop indefinitely.
- **`HOTLINE_REMOTE_SSH_PERSIST=<seconds>`** — how long the shared ssh connection
  outlives the last hop (default 300). One `ControlMaster` connection is shared by
  every process of one dial, so the tailnet check and any key handshake happen once;
  this has to outlast the gap between the dial returning and the response wait
  starting.
- **`HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT=<seconds>`** — ssh's own connect budget
  (default 10).

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
