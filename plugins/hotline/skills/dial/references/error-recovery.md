# Hotline Error Recovery

Common failure modes and how to recover from them.

`dial.sh` reports failures as `{"status":"error","stage":…,"detail":…,"recovery":…}`.
The stage tells you which section below to read:

| `.stage` | Section |
|---|---|
| `args` | (a malformed invocation — `.recovery` says which flag) |
| `identity` | [Identity Failures](#identity-failures) |
| `resolve` | [Workspace Resolution Failures](#workspace-resolution-failures), [Identity Cache Issues](#identity-cache-issues) |
| `transport` | [herdr Failures](#herdr-failures) — the backend the caller asked for cannot host this call. **Never a degradation**; `.recovery` names the fix. |
| `fire` | [CMUX Failures](#cmux-failures), [Headless Call Failures](#headless-call-failures), [herdr Failures](#herdr-failures) |
| `boot` | [CMUX Failures](#cmux-failures) — the callee's REPL never came up |
| `deliver` | [Delivery](#delivery-stage-deliver-and-messages-that-appear-to-vanish) — the REPL came up but the message never landed in it. **A live pane is sitting empty; the prompt is still on disk. Do not re-dial blind.** |

## Identity Failures

Identity normally resolves inline from `$CLAUDE_CODE_SESSION_ID` (Claude Code >= 2.1.132) or `$CODEX_THREAD_ID`, in the same call as the rest of the dial. An `identity` stage error means every rung of the precedence chain missed — including the legacy fingerprint fallback.

**You got a `replay`, or `caller_kind` wasn't `native`, on a Claude caller**
- Not a failure: the legacy fingerprint fallback engaged and the call still completes on the re-run. It means `$CLAUDE_CODE_SESSION_ID` was either absent — a pre-2.1.132 Claude Code, or an environment that strips it (a wrapper, a sanitized shell, a launcher that scrubs env) — or present but not a UUID, in which case `session-init.sh` validates it, skips it, and falls through rather than propagate a bad ID.
- Worth checking if you expected the one-call path: `printf '%s\n' "$CLAUDE_CODE_SESSION_ID"` and `claude --version`. Version >= 2.1.132 with an empty value inside a Bash tool call means something in the environment is dropping it.

**"Could not find claude process in ancestry"**
- The legacy fallback ran and found no `claude` ancestor — so you're not inside a Claude Code session, or the process tree is unusual, *and* no native or Codex identity was available either.
- **If you're running under Codex:** this is expected — Codex has no `claude` ancestor. `session-init.sh` should have already returned a `caller_kind: "codex"` identity instead of this error. If you still see the error under Codex, confirm `$CODEX_THREAD_ID` is set in your shell (`printf '%s\n' "$CODEX_THREAD_ID"`) and see `references/codex-caller.md`.
- Recovery (other non-Claude callers): set `HOTLINE_CALLER_SESSION_ID=<stable-id>` in the environment to supply a caller identity directly, or ask the user for their session ID. As a last resort, proceed with a generated UUID — dialing works, but session caching won't persist across restarts.

**"Fingerprint not found in recent transcripts"** (legacy fallback only)
- The fingerprint was planted but the transcript file wasn't written yet (both steps ran in the same tool call), or the transcript directory path doesn't match.
- Recovery: `session-init.sh` and `session-init.sh discover` must run in **separate** tool calls (this is what `dial.sh`'s `status: replay` round-trip is for — re-run the identical command). If it still fails, check that `~/.claude/projects/` contains transcript files for the current directory.

## Workspace Resolution Failures

**"No entry for '<id>'"**
- The dirmap ID doesn't exist in `~/.dirmap.json`.
- Recovery: Run `dirmap list` (or `dirmap-fallback.sh list`) to show available IDs. Ask the user which one they meant.

**"Path does not exist: <path>"**
- The resolved path doesn't exist on disk.
- Recovery: The project may have been moved or deleted. Ask the user for the correct path.

**Exit 1 with candidates JSON on stderr**
- Multiple fuzzy matches found, none confident enough to auto-select.
- Recovery: This is normal — present the candidates to the user and ask them to pick.

**"Could not resolve '<reference>'"**
- No dirmap entries, no identity matches, nothing.
- Recovery: Ask the user for an exact path or dirmap ID. Suggest they add the workspace to `~/.dirmap.json`.

## Headless Call Failures

**`{"error": "Claude CLI returned no output"}`**
- The `claude -p` command failed silently or timed out.
- Recovery: Check the stderr captured in the error message. Common causes: auth issues, rate limits, invalid workspace path. Retry once, then report to the user.

**`{"error": "No --cwd provided for first contact"}`**
- Bug in the dial flow — first contact requires `--cwd`.
- Recovery: Ensure `--cwd "$TARGET_PATH"` is passed on first contact. This shouldn't happen if the decision tree is followed correctly.

**Empty or malformed JSON response**
- The remote agent's response couldn't be parsed.
- Recovery: Check the raw `claude -p` output. The remote workspace may not have the hotline plugin installed. Ask the user to verify.

## Session Cache Issues

**Stale session — `--resume` fails**
- The cached session ID is from a previous Claude run and no longer valid.
- Recovery: Clear the session cache entry and start fresh:
  ```bash
  # The session-cache.sh set command will overwrite the stale entry
  bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
    --caller-session "$MY_SESSION_ID" --session "$NEW_SESSION_ID" --mode "$MODE"
  ```

**Two agents in same directory colliding**
- The legacy fingerprint cache is keyed by claude PID, so this shouldn't happen (and can't at all on the native path, where each session reads its own `$CLAUDE_CODE_SESSION_ID`). If it does, the `/tmp/claude-session-<pid>` files may be stale.
- Recovery: Delete `/tmp/claude-session-*` files and re-run `session-init.sh`.

## CMUX Failures

**`cmux ping` fails**
- CMUX is installed but not running.
- Recovery: nothing to do by hand. Transport selection happens before the launch, so
  `dial.sh` fires the call headless itself and records `cmux-unavailable→headless` in
  `.fallbacks`. cmux is optional; tell the user about the degradation when a visible
  pane was the point.

**`stage: "boot"` — "Claude Code's startup TRUST DIALOG is on screen"**
- The callee was launched into a directory Claude Code has not trusted, so it parked
  on the startup trust prompt: no banner, no session (so no transcript), no input box
  — none of the boot wait's three signals can fire. Before this was recognized, the
  wait spent its whole 60s budget and then blamed a malformed `--allowedTools` or a
  lost tty, and never said "trust" (claude-plugins-6y0s). It is the cmux twin of the
  herdr arm's pre-submit refusal below, with the same semantics.
- **Nothing was delivered**: the prompt is pasted in a later step, so the callee has
  received nothing and re-dialing after trusting the directory is safe. Do not send
  anything into that pane — the dialog takes keystrokes and its default option is
  `No, exit`.
- Recovery: run `claude` in the callee's directory once and answer *Yes, I trust this
  folder*, then re-dial. A fresh `git init` directory gets its own trust boundary even
  under an already-trusted parent, and `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS` does
  **not** cover this — directory trust is not a permission mode.
- **A cmux CONFERENCE reports the same refusal as `stage: "deliver"`**, wrapped in
  "the conference REPL booted but the prompt never landed in it". It never reaches the
  boot wait — `dial.sh` step 5b goes through `cmux-call.sh` to `cmux-paste.sh`, whose
  `--wait-box` loop makes the identical refusal (one wording, in `repl-state.sh`).
  Read it as this section, not as a lost paste: nothing was pasted, and re-dialing
  after trusting the directory is safe.

**"Failed to create CMUX workspace"** (`stage: "fire"`)
- CMUX couldn't open a new workspace (maybe at workspace limit).
- Recovery: this one does *not* auto-degrade — the launcher failed after transport was
  already chosen. Report `.detail`, then re-dial with `--headless` to get the call
  through without a pane.

### Surface placement (side-by-side / `--window`)

**`{"fallback":"headless"}` returned instead of a `call_dir`**
- cmux is up but the `cmux-cli` plugin isn't installed, so the side-by-side opener (`open-side-surface.sh`) couldn't be resolved. This is expected, not an error.
- Recovery: none needed by hand — `dial.sh` re-fires the call through the headless transport itself and records `cmux-cli-missing→headless` in `.fallbacks`. To force side-by-side, install the `cmux-cli` plugin; or pass `--detached` / `--window` (neither needs `cmux-cli`).

**`open-side-surface failed` / `open-window-surface failed` in error.txt (opener resolved but errored)**
- The opener ran but couldn't create the surface — usually `cmux identify` failed (socket unreachable) or `cmux tree` returned no panes.
- Recovery: the error.txt carries the opener's stderr. If cmux itself is fine, retry with `--detached` (new-workspace placement, no `cmux identify` dependency). If `cmux identify` consistently fails, force headless with `--headless`.

**`surface <ref> PTY never became ready`**
- The new surface was created but its shell never echoed the readiness probe within the timeout (`surface-ready.sh` exited 3). Common causes: a very slow shell rc, a non-shell program in the surface, or the PTY backend never attaching.
- Recovery: the launcher already closed the surface (no orphan) and wrote the async error. Bump the budget with `HOTLINE_SURFACE_READY_TIMEOUT=<seconds>` (default 8) and retry, or use `--detached`.

**"Terminal surface not found" / "Failed to read terminal text" mid-call**
- The surface lost (or never attached) its PTY. `cmux send` is what attaches it, lazily, on first send — so the readiness probe (`surface-ready.sh`) is the recovery, and it runs before the launch command. Nothing focuses the pane to force attachment: focus moves the user's cursor into the callee's shell, which is how their keystrokes end up prepended to a launch command.
- Recovery: if the user closed the surface, the call is gone — re-dial. Otherwise retry; the readiness probe normally handles transient attach races.

**`--window <name>` keeps creating new windows**
- cmux windows are not directly name-addressable, so Hotline identifies a "named window" by a workspace titled `<name>` inside it. If that titled workspace was renamed or closed, the next `--window <name>` won't find it and will create a fresh window.
- Recovery: pass the explicit `window:<n>` ref instead of a name when you need to target a specific existing window, or accept that the name reseeds a new window + titled workspace.

### Delivery: `stage: "deliver"` and messages that appear to vanish

Every cmux message — first contact, follow-up, conference — is delivered by
`cmux-paste.sh` over cmux's control socket via `terminal.paste`, which then proves
the call's nonce reached the callee. There is no escaping hazard to reason about
(`json.dumps` escapes the payload in-process; a live probe put 16MB through one
request line).

Almost every payload goes in one paste with its submit key. The one exception is
first contact, where the payload is a `/hotline:…-ringing` slash command with a
work-order body: CC collapses a single large paste to a `[Pasted text +N lines]`
placeholder, and a placeholder at the start of the input has no leading `/`, so the
slash never parses and the callee gets the work order as plain text with no
protocol (claude-plugins-pmgb). For that case `cmux-paste.sh` sends the invocation
line as its own small paste (it renders verbatim, so the command parses), then the
body as a second paste (CC expands its placeholder inside the command args on
submit), then a separate Enter key event to submit. So for first contact a submit
key IS sent separately; for everything else nothing is typed and no separate submit
is sent.

**`stage: "deliver"` means: the REPL is up, and it was never told anything.** The
pane is live and empty. This is the one error stage that leaves something running
behind it. Three rules:

1. **Read `.detail`.** It carries the reason the paste could not be confirmed, and
   the reasons are materially different: a surface that never drew an input box, a
   `terminal.paste` the socket rejected, a nonce that turned up nowhere.
2. **`$call_dir/pending_paste.md` still holds the prompt** — after a `deliver`
   failure it is the only copy. That is true of every transport: first contact,
   follow-up and conference all leave the same file in the same place, and
   `.recovery` names it. Recover it before you remove the call dir.
3. **Establish whether it landed before any re-dial.** Confirmation gives up after a
   bounded poll, so a paste that arrived a moment later is indistinguishable from one
   that never arrived — and re-dialling on that ambiguity delivers the work order
   **twice**.

To find out which happened, read the callee's transcript for the nonce
(`jq` the JSONL under `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`) —
that is byte-definitive, where the screen is not.

**A follow-up gets this too, and that is deliberate.** When reuse cannot confirm its
paste it reports `deliver` rather than falling back to a fresh surface, because the
fresh path would re-deliver the same prompt into a `--resume` of the same session —
so a payload that actually landed would be executed **twice**. The fresh-surface
fallback is reserved for refusals that happen BEFORE anything is sent (no input box,
surface gone, an RPC the socket rejected); those are safe, because the callee
received nothing.

**Two things are NOT proof that a message failed to arrive:**

- **A missing user record.** A payload pasted into a busy REPL is queued and
  written as a `queued_command` attachment, with **no user turn at all**, even
  though the callee reads and answers it. A verifier that counts user turns reads
  a perfectly landed message as lost. (`transcript-extract.sh` counts the
  attachment, the receiver's own `STATUS:` line, and the `enqueue` record for
  exactly this reason.)
- **Text visible in the input box.** A queued message is drawn there while it
  waits, alongside `Press up to edit queued messages`. A large paste renders as a
  `[Pasted text +N lines]` placeholder instead, so the nonce is genuinely not on
  screen even though delivery succeeded.

**But neither is text in the input box proof it DID arrive and submit.** Confirmation
scopes every screen-side marker — `[Pasted text`, the nonce, the queued-messages hint
— to the screen OUTSIDE the live input box. A marker in the box proves the payload
ARRIVED; only one rendered elsewhere (an echoed turn above the box, the queued hint)
says anything about whether it SUBMITTED. The two readings are the same pixels, so
`cmux-paste.sh` tests the negative one first: the parked classifier runs before the
screen tier, and only when it refuses does a marker get to confirm. Read the same way
when you are doing this by hand — `❯ [Pasted text #2 +18 lines]` on the box line is a
message waiting for an Enter, not a message that went.

**Never press Enter on a surface to "help" a stuck message.** `submit_key` already
submitted it; an extra Enter on a queued or already-submitted payload is a double
submit. If a payload really is sitting unsubmitted in the box, the right move is to
let the dial fail and recover the prompt from `pending_paste.md`.

`cmux-paste.sh` does fire exactly one corrective Enter, and that is not a licence to
do it by hand. It has what you do not: the nonce it just minted, a pre-paste snapshot
of the box, and refusals for every ambiguous state (busy, queued, post-interrupt,
scrolled viewport, box contents unchanged since before the paste). It reports the
Enter as `retried_enter: true` and re-proves submission afterwards by positive
evidence only. `wait-for-response.sh` never sends one — when it finds a payload parked
it says so and stops, because it cannot tell a parked payload from one that submitted
a moment after it looked.

#### Recover by re-delivering, never by hand-typing with `cmux send`

When a delivery fails, the tempting move is to type the payload in yourself with
`cmux send` plus `cmux send-key Enter`. Read `cmux read-screen` to find out what
happened, then re-deliver through `terminal.paste`. `cmux send` cannot carry a work
order intact, for three independent reasons.

- **A trailing `\n` in a `cmux send` does not submit.** The target is a claude
  TUI/Ink REPL reading through bracketed paste, so the newline lands as a
  **literal line break in the input box** (stored as CR, `0x0D`) and no submit
  registers. It does **not** submit early. Submitting anything through `cmux send`
  therefore takes a separate `send-key Enter` (claude-plugins-5zhp / -8bfd, claude
  2.1.221 / cmux 0.64.20).
- **`cmux send` loses bytes, and not by size.** There is **no size threshold**.
  Across 12 controlled sends from 507 B to 16 KB, one silently
  lost 2,538 contiguous middle bytes from a 3,045 B payload — one user event, no
  error, the bytes provably absent from the transcript — and a separate ~16 KB
  trial lost 3,066. Sends have also been seen **fragmenting into 3–7 separately
  submitted turns** in real traffic while refusing to reproduce under test. The
  failure is **sporadic** and the trigger is unknown, so a successful `cmux send`
  means "bytes reached the PTY" and nothing more.
- **It rewrites `\n`, `\r` and `\t` in its argument**, with **no backslash escape**
  to opt out (`\\` arrives as two backslashes, so doubling makes it worse). Getting
  exact bytes through it means **splitting the payload** just after each backslash
  preceding `n`/`r`/`t`.
  For **plain text**, escaping is never the cause of a vanished message — but for a payload containing those sequences it can be, so the reassurance is scoped to plain text only.

`terminal.paste` has none of these properties: one request line, the payload
JSON-escaped in-process, and a `submit_key` that submits. Re-deliver through it —
after establishing from the transcript that the first attempt really did not land.

**A surface whose REPL exited is refused, not pasted into.** If a callee ran
`/exit`, or claude crashed, the surface still exists and its cached handle still
resolves — but what is drawn is a shell prompt. Reuse checks for the input box (a
`❯` padded with U+00A0, which a shell prompt does not produce) and falls back to a
fresh surface with a reason, because pasting a work order at a shell with
`submit_key: "return"` would make the shell **run** it.

### Surface reuse (follow-ups into a live REPL)

`dial.sh` routes a follow-up into the surface the callee's session already
occupies, and only opens a fresh surface when that is refused — which it records as
`surface-reuse→fresh(<reason>)` in `.fallbacks`. `cmux-reuse-surface.sh`'s header
documents every refusal condition: a surface that is gone, one showing no input
box, the post-interrupt "what should Claude do instead?" state, unsent text in the
box while a turn is in flight, and a box that would not clear. All of them happen
BEFORE anything is sent, so all of them are reasons, never errors — the follow-up
still gets through, on a fresh surface. A paste that went out and could not be
confirmed is the exception and is not in that list: it is a `deliver` error, for the
double-execution reason above.

**Text in the box is not always unsent text.** Claude Code draws its ghost suggested
prompt, its queued-messages hint and `Message @agent…` from a placeholder prop while
the input's value is empty, and `cmux read-screen` renders a placeholder and typed
input identically. Such a box is reused as-is: no Ctrl-C, no verify, the follow-up
pastes straight in. The judgement comes from the styled render grid
(`terminal.replay`, capability `terminal.render_grid.v1`), where a placeholder is
dim — so a cmux without that capability, or an RPC that fails, reads the box as real
text and takes the clear-then-verify path instead. That direction costs at most one
fresh surface; the other would paste a work order on top of a human's half-typed
words. (`cmux-rpc.md` covers that call's semantics — `anchor`, the snake_case
addressing rule, and why `result.surface_id` has to be checked before the grid is
trusted.)

`close-superseded-surface.sh` asks the same question for the opposite purpose: a
proven placeholder is no reason to keep a superseded surface, so the dead pane gets
closed instead of accumulating behind a long conversation. Only the polarity of the
fallback differs — that path DESTROYS the surface, so an unproven box (no capability,
a refused RPC, a workspace that will not resolve) counts as real text and the surface
is kept, reported as `surface-cleanup-skipped(parked-input)`.

## herdr Failures

The herdr transport is opt-in (`--transport herdr`, or `HOTLINE_TRANSPORT_AUTO=1`
inside a herdr pane). It hosts the callee locally by default and on another box
with `--remote <ssh-target>` — see **Remote herdr Failures** below for the
failures that only exist across the wire.
Every refusal below is a **refusal, not a degradation**: the caller asked for a
callee that survives a disconnect, and quietly giving them a cmux surface instead
would be a lie they discover hours later. Report `.detail` and `.recovery` as-is.

**`stage: transport` — "herdr is not on PATH" / "no server answered" / "no pane could be resolved"**
- The three preflight questions, in order. Each needs a different action: install
  herdr; start it (`herdr` in a terminal, or `herdr session list` to see what is up);
  or open a pane for it to split (any pane will do) / name one with
  `HOTLINE_HERDR_PANE=<pane-id>`.
- Recovery: fix the one it named, or drop `--transport herdr` to use the cmux default.

**`stage: args` — "supports --placement side and detached, not window" / "cannot adopt an existing session (--resume)"**
- Not a malfunction: these are herdr's remaining boundaries, and each message names
  what is actually missing. `--window` has no herdr implementation at all — hotline
  splits a pane and never creates herdr workspaces or tabs, so there is no window to
  place a callee in. `--resume` is a conflict rather than a gap: herdr hosts a callee
  it *starts*, with a `--session-id` preset that is the only reason the transcript is
  readable, and `claude --resume` cannot take that preset.
- Recovery: re-dial without `--window` (side or detached), or over cmux when a real
  window is the point. To continue a session you already dialed, drop `--resume`
  entirely — the cached herdr agent is re-targeted by name with no flag at all.

**`stage: args` — "--remote names a box to host the callee, and --transport … cannot host one"**
- `--remote` is a transport CHOICE: herdr is the only backend that can host anywhere
  but here, so `--remote` selects it on its own. Naming `cmux` or `headless` alongside
  it is two explicit, incompatible asks.
- Recovery: drop `--transport` (`--remote <target>` alone is the whole invocation),
  or drop `--remote` to dial that transport locally.

**`stage: fire` — "herdr pane split failed" / "herdr agent start failed" / "interactive_ready:false"**
- The pane opened but no claude was detected in it, or herdr said it is not ready for
  input. `error.txt` in the call dir carries herdr's own diagnostic, and the pane has
  been closed so nothing leaks — set `HOTLINE_HERDR_KEEP_FAILED_PANE=1` and re-dial to
  keep it and read its scrollback.
- `agent_pane_busy` is retried automatically (a freshly split pane needs a moment at
  its shell prompt); seeing it in a final error means it never settled.

**A slash-command payload goes out as TWO writes, not one**
- `agent prompt` submits text and Enter atomically, which is right for an ordinary
  payload and wrong for a `/hotline:…-ringing` invocation with a work-order body: CC
  collapses the multi-line paste, the input no longer *starts* with `/`, and the callee
  reads the work order as plain text with no protocol — no STATUS, no call_id, and
  `transcript-extract.sh` exits 10 forever while the answer sits in the transcript
  (claude-plugins-fvhx). So `herdr-prompt.sh` writes the invocation line alone with
  `pane send-text` (literal text, no Enter, nothing submitted), then submits the body
  with `agent prompt`; CC expands the body's placeholder inside the command args. This
  is the same rule the cmux path splits on (one predicate in `repl-state.sh`).
- `"reports no pane_id"` is that split refusing rather than falling back: an unsplit
  delivery would put the nonce in the transcript, report *confirmed*, and leave the
  caller waiting forever for a protocol that never engaged. `sent` is `false` —
  nothing was written — so re-dialing is safe. Check `herdr agent get <name>`.

**`stage: deliver` — "is sitting on Claude Code's startup TRUST DIALOG"**
- The one startup gate herdr's own signals cannot see: with the trust dialog on screen
  `agent start` reports `interactive_ready:true, agent_status:"idle"` — true in its own
  terms, since the dialog takes keystrokes — so the readiness gate below passes it. The
  dialog's default option is **`No, exit`**, so a submitted work order answers it that
  way and the callee exits: no turn, no transcript, the work order gone
  (claude-plugins-59ry). First contact therefore reads the screen once and refuses.
- **Pre-submit**: `sent` is `false`, `pending_paste.md` still holds the payload, and
  re-dialing cannot double-run anything.
- Recovery: Claude Code has to trust the directory. Run `claude` in it once and answer
  *Yes, I trust this folder*, or `herdr agent attach <name>` and answer it there, then
  re-dial. Note that **a fresh `git init` directory gets its own trust boundary** even
  under an already-trusted parent, and that
  `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS` does **not** cover this — directory trust is
  not a permission mode.

**`stage: deliver` — "is 'blocked' before first contact" / "never reported interactive_ready"**
- Both are **pre-submit refusals**: the opening payload was held back, `sent` is
  `false`, and `<call_dir>/pending_paste.md` still holds it. Nothing reached the
  callee, so re-dialing cannot double-run anything.
- `blocked` before first contact means the callee came up on a gate — most often a
  startup trust prompt — and that gate takes keystrokes, so a work order submitted
  into it would answer the dialog and never become a turn. `herdr agent attach <name>`
  shows what it is asking. Unattended callees avoid the permission half by dialing
  with `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1` (a real trust decision).
- "never reported interactive_ready" means `agent start` claimed the REPL was ready
  and `agent get` no longer agrees. Attach and look at the pane; if the machine was
  simply loaded, raise `HOTLINE_HERDR_READY_TRIES` / `HOTLINE_HERDR_FIRST_SETTLE`.

**`stage: deliver` — the nonce never reached the callee's transcript**
- On FIRST contact this is reported after a budget four times the follow-up one
  (`HOTLINE_HERDR_FIRST_CONFIRM_TRIES`), because the transcript has to be *created*
  rather than appended. Raise it before concluding a payload was lost on a loaded box.
- **There is no screen fallback for herdr, by design.** A claude REPL is a
  full-screen alternate-screen TUI, and rows that leave the alternate screen never
  enter herdr's scrollback — so `agent read` cannot confirm what the transcript
  missed, and hotline reports "unconfirmed" instead of scraping something weaker.
- The payload is still in `<call_dir>/pending_paste.md` and the agent is still live:
  `herdr agent attach <name>` (the name is in `<call_dir>/herdr_agent.txt` and in
  `.surface_ref`). **The error itself carries `sent`** — when it is `true` the callee
  may well have received the payload after the confirmation window, so read its
  transcript for the call_id before doing anything, and do NOT re-dial blind.

**The response wait says "agent … is gone"**
- herdr clears an agent's name when it exits, so the callee died before answering.
  Its transcript is still on disk; read it. This fails fast rather than sitting out
  the 30-minute budget, which is the one thing herdr's lifecycle states buy the wait.

**The response wait exits 5 — "is BLOCKED … waiting on INPUT"**
- Not a failure and not a timeout. herdr reported the callee's lifecycle as `blocked`
  with no terminal STATUS for the nonce: it is sitting on a permission gate, or it
  asked a question. More waiting cannot clear it — a human has to.
- `herdr agent attach <name>` (the name is in `<call_dir>/herdr_agent.txt` and in
  `.surface_ref`) shows what it is actually asking. Tell the user what it needs.
- **Resumable.** The call is marked the same way an expired budget is, so once the
  callee is unblocked, re-running `wait-for-response.sh` on the same call_dir reads
  the answer with a fresh budget. It sends nothing, so it can never double-queue.
- Unattended callees avoid the permission half of this by dialing with
  `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1` — a real trust decision, not a default.
- The state is always re-probed before the call ends on it, so a `blocked` blink
  (a gate the callee's own hook answered) leaves the wait running instead.

**`stage: transport` — "herdr agent … is BLOCKED and cannot take a follow-up"**
- The cached agent is alive and confirmed (two reads) waiting on **input** — a
  permission gate, or a question. Nothing was submitted to it and nothing was
  started, so there is nothing to undo.
- **hotline deliberately does not start a fresh callee here**, unlike every other
  refused reuse. That agent holds the only copy of the conversation; a second callee
  would leave it running, unreachable through hotline, and take the cache with it.
- `herdr agent attach <name>` shows what it is asking. Once a human clears it,
  re-dial exactly as before — the same agent is re-targeted and its context is
  intact. Unattended callees avoid the permission half with
  `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS=1` (a real trust decision).

**`.fallbacks` says `herdr-agent-reuse→fresh(…)` on a follow-up**
- The cached agent could not be re-targeted: it has exited (which is the only reason
  left — a `blocked` one fails the dial instead, see above). hotline started a fresh
  callee rather than failing.
- **The cost is in the entry, and it is real: the fresh callee has none of the prior
  conversation.** herdr cannot re-host an existing claude session — `claude --resume`
  and the `--session-id` preset the transcript path depends on are mutually
  exclusive. If the follow-up only makes sense with the earlier context, re-send it
  self-contained, or continue over cmux (which *can* resume the session).
- `callee-session-changed(old→new)` alongside it is the cache being re-keyed to the
  new session, so the NEXT follow-up addresses the callee that is actually live.

**A pane is left over after a finished call**
- Expected. Persistence is why herdr exists, and a follow-up re-targets that same
  agent, so hotline does not close it the way it closes a detached cmux tab.
  Teardown: `herdr pane close $(cat <call_dir>/herdr_pane.txt)`, or
  `ssh <.remote_target> herdr pane close <.remote_pane>` for a remote call — both
  handles are in the emitted JSON for exactly this.

## Remote herdr Failures (`--remote <ssh-target>`)

Everything in **herdr Failures** applies unchanged: the launch, the delivery proof,
the trust-dialog refusal and the lifecycle gate are the same code, running one ssh
hop away. What follows is only what the hop adds. `--remote` is an explicit ask with
no local substitute, so every one of these is an **error**, never a quiet local call.

**`stage: transport` — "could not be reached over ssh"**
- The hop failed before anything about herdr was asked, which is the right order:
  reporting "herdr is not installed" about a box we could not reach would be a lie.
- Recovery is in the message: prove `ssh -o BatchMode=yes <target> true` by hand. It
  has to work **non-interactively** — hotline never answers a password or a browser
  check. The three usual causes:
  - **the wrong host.** A tailnet MagicDNS name and its `.local` mDNS name are
    different hosts: the first goes through Tailscale SSH, the second to plain
    `sshd`, which then denies publickey. `foo` and `foo.local` failing differently
    is the tell.
  - **the wrong user.** A tailnet SSH policy grants specific users; one that is not
    permitted is refused with "tailnet policy does not permit you to SSH as user X"
    however good your keys are.
  - **no identity available.** Under Tailscale SSH none is needed; under plain sshd
    an agent or key has to be there for a non-interactive hop.

**`stage: transport` — "Tailscale SSH wants a browser check" / a hop that "timed out"**
- Tailscale SSH can run in **check mode**: it prints
  `# Tailscale SSH requires an additional check. To authenticate, visit
  https://login.tailscale.com/a/…` and, once the check period has lapsed, a
  `BatchMode` hop blocks on an authentication it cannot perform.
- Every hop is time-boxed precisely so that becomes an error naming the URL rather
  than a half-hour of silence mid-work-order. Those notice lines are also filtered
  out of every read — nothing downstream ever parses them as data.
- Recovery: the **user** visits the URL (or runs `ssh <target> true` themselves once),
  then re-dial. Raising `HOTLINE_REMOTE_SSH_TIMEOUT` cannot help: nothing is going to
  answer the browser.

**`stage: transport` — "herdr is not on PATH on <target>" / "no server answered" / "no pane could be resolved"**
- The same three questions, asked of that box. Two things differ:
  - **`HERDR_ENV=1` proves nothing here.** Being inside a herdr pane means a server
    hosts *this* process; the remote server is checked outright, so a stopped one is
    reported as a stopped server rather than as "no pane to split".
  - **the pane override is `HOTLINE_HERDR_REMOTE_PANE`**, not `HOTLINE_HERDR_PANE`.
    A pane id means nothing on another machine, so the local override is ignored for
    a remote dial (as is the caller's own `$HERDR_PANE_ID`).

**`stage: transport` — "claude is not on the PATH a non-login ssh command gets"**
- The one preflight check with no local counterpart. `ssh host cmd` runs with that
  box's own non-login PATH, so a `claude` under `~/.local/bin` can resolve for a human
  who logged in and not for the command that starts the agent.
- Recovery: `ssh <target> command -v claude`. If it resolves interactively but not
  there, add its directory to that box's non-login environment
  (`~/.ssh/environment`, or whatever rc the ssh command actually reads).

**The response wait says "No transcript at any derived path"**
- The paths it names are on the REMOTE box: `~/.claude/projects/<encoded
  realpath>/<session>.jsonl` under **that** box's `$HOME`, with the realpath resolved
  **there**. Both halves are asked of it rather than assumed from here, which is what
  makes a symlinked remote checkout readable at all.
- So check the file on that box — `ssh <target> ls ~/.claude/projects/…` — before
  concluding delivery failed. `<call_dir>/remote_transcript.jsonl` is the local mirror
  the waiter last fetched, and is worth reading first.

**The wait reports the agent as gone, or asks about the wrong box**
- `<call_dir>/remote_target.txt` is what tells the waiter the agent lives elsewhere;
  it runs as a separate process and receives nothing else. Missing or empty, the LOCAL
  herdr is asked, answers "no such agent", and a working callee is reported dead.
- If that file is absent from a remote call's dir, it is a launcher bug — do not
  re-dial without looking.

**`stage: "transport"` — "this target's callee is herdr agent … on \<box>"**
- The cache says this target's callee lives on a box this dial is not addressing: a
  `--remote` workspace re-dialed without the flag, without it re-dialed *with* one, or
  with a different box named. **Nothing was started and the cache is untouched.**
- It is refused rather than degraded because a fresh callee here does not replace that
  one. `surface_ref` is an opaque string — a herdr agent name on one machine is
  indistinguishable from one on another (claude-plugins-7wze.11) — and the cache write
  a new callee triggers REPLACES the entry that named the old one, so the remote
  conversation is left running with nothing pointing at it and the next identical
  re-dial mismatches again.
- Two moves, and the `.recovery` names both with the actual box filled in:
  - **Continue it** — re-dial with `--remote <that box>` (or with no `--remote`, when
    the cached callee is the local one). Its context is intact and the cached handle
    is re-addressed by name.
  - **Abandon it** — add `--fresh`. The dial proceeds, and `.fallbacks` gains
    `abandoned-callee(<agent> on <box>; …)` naming what is now running unattended.
    Close it with the command that entry carries: `ssh <box> herdr pane close <pane>`
    when a call dir still remembers the pane, otherwise `ssh <box> herdr agent list`
    to find it.

**`.fallbacks` says `session-cache→fresh(transport …→…)`**
- The cached handle belongs to a different BACKEND on this machine — a cmux surface is
  not a herdr agent name — so it was not re-addressed and the new callee starts without
  the prior context. This one stays a fallback rather than a refusal: both handles are
  local, so the superseded one is still on the user's own screen.

## Identity Cache Issues

**Stale identity — resolution picks wrong workspace**
- The cached identity is outdated (project changed significantly).
- Recovery: Run `hotline-pickup` with `--fresh` on the target workspace to regenerate:
  ```bash
  bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
    --prompt "/hotline:hotline-pickup --fresh"
  ```

## General Principles

1. **Report, then let the user decide on a retry.** A `deliver` failure is the one that
   never gets re-dialled on ambiguity — see [Delivery](#delivery-stage-deliver-and-messages-that-appear-to-vanish).
2. **The wrapper degrades; you explain which degradation happened.** cmux → headless,
   cached session → fresh session, refused surface reuse → fresh surface: `dial.sh`
   takes each of those itself and names it in `.fallbacks`.
3. **Quote the actual error message** when reporting to the user, not a paraphrase.
4. **Ask when resolution is ambiguous.** Several fuzzy candidates is the user's call.
   A stale session gets started fresh.
