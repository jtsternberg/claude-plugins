# Hotline Error Recovery

Common failure modes and how to recover from them.

`dial.sh` reports failures as `{"status":"error","stage":…,"detail":…,"recovery":…}`.
The stage tells you which section below to read:

| `.stage` | Section |
|---|---|
| `args` | (a malformed invocation — `.recovery` says which flag) |
| `identity` | [Identity Failures](#identity-failures) |
| `resolve` | [Workspace Resolution Failures](#workspace-resolution-failures), [Identity Cache Issues](#identity-cache-issues) |
| `fire` | [CMUX Failures](#cmux-failures), [Headless Call Failures](#headless-call-failures) |
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

**"Terminal surface not found" mid-call**
- The surface lost (or never attached) its PTY. The wait scripts re-`focus-pane` the surface's pane each poll in surface mode to recover, but a surface the user manually closed can't be recovered.
- Recovery: if the user closed the surface, the call is gone — re-dial. Otherwise retry; the readiness probe + focus-pane normally handles transient attach races.

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
