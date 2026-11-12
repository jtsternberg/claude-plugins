# Terminal Io

Read before sending text or keys, interpreting agent REPL state, or using a structured terminal grid.

Resolve and validate `WS` (workspace UUID) and `SID` (surface UUID) through the
main skill's targeting procedure before using the examples. Keep both flags on
cross-workspace calls. Event length comparisons below require cmux 0.65.0+;
earlier builds cap `message_length` at 240. Follow the version-aware measurement
and surface/session filters in the events reference, rather than treating a
workspace-only match as proof when several agents share that workspace.

### Read the screen

```bash
cmux read-screen --help
```

Use `--scrollback --lines <n>` to grab history. Without them you only get the visible viewport — often omitting the command output you actually care about.

#### Gotcha: Claude Code's grayed-out next-prompt suggestion looks like real input

When the surface you're reading is running **Claude Code** (the `claude` CLI in its REPL), Claude Code renders an autosuggest hint inside its input box — a slightly-grayed string showing what it predicts the user might type next. In `cmux read-screen` output that hint appears as plain text on the prompt line, **indistinguishable from text the user actually typed**.

This has burned previous agents who were watching another claude session via `read-screen`: they saw the ghost suggestion, assumed *the user* had entered that command, and started narrating phantom actions ("the user just asked you to do X, and you're now running it…") — when in reality the user had typed nothing and the inner agent was still idle.

How to tell the difference:

- **Real submitted user input** is followed by output (assistant response, tool calls, screen updates further down). The prompt is usually empty or shows the *next* incoming suggestion.
- **A ghost autosuggest** sits alone inside the input box (e.g. `╭─...─╮ / │ > update the PR description / ╰─...─╯`) with no output below it, and the cursor often sits at column 0–1 of that line, not at the end of the suggested text.

When in doubt, don't infer intent from a single `read-screen` snapshot of a claude-running surface. Re-read after a moment — real input commits and gets replaced by output; ghost text either persists unchanged or disappears as the user types something different.

Same caveat applies to other agent REPLs that render input autosuggestions (opencode, omc/omx, etc.). The pattern — text inside the input prompt with no downstream activity — is the tell, regardless of vendor.

#### Gotcha: `read-screen` returns the *scrolled* viewport, not the live bottom

**Use `cmux read-screen --surface <id> --scrollback --lines <n>` for every read you will make a decision on.** Bare `read-screen` captures whatever the surface is currently showing, so if the **user has scrolled the surface up** (mouse wheel / trackpad in the cmux GUI) you get stale content from higher in the buffer. The `--scrollback --lines <n>` form reads history plus the active tail and is **viewport-independent** — verified live on cmux 0.64.22 against a pane scrolled to ~line 225, where it returned the live tail while the bare form returned the scrolled view (and confirmed in cmux's own `TerminalControllerTerminalTextTests.swift`).

The stale-capture tell below still matters for the bare form, and for reasoning about a capture you did not take yourself:

```
Jump to bottom (click) ↓
```

**Real failure this caused:** an agent sent a message (`cmux send` + `send-key enter`), then `read-screen` showed no trace of it and an empty prompt, so the agent concluded the send failed and re-sent — double-queuing the message. The message *had* landed; the viewport was just scrolled up.

Second tell it missed: a line reading

```
Press up to edit queued messages
```

means messages were **queued** while the REPL was busy — i.e. your send *did* land and is waiting to be processed. Seeing it is confirmation of success, not failure.

**Detection — before concluding a send failed, grep the output for both markers** (a `--scrollback` read should not show `Jump to bottom` at all, so seeing it means something took a bare capture):

```bash
out=$(cmux read-screen --workspace "$WS" --surface "$SID" --scrollback --lines 80)
printf '%s\n' "$out" | grep -qF 'Jump to bottom'            && echo "SCROLLED — view is stale, NOT a failed send"
printf '%s\n' "$out" | grep -qF 'Press up to edit queued'   && echo "QUEUED — your send landed and is waiting"
```

**Remedy — read the live tail instead of trying to move the viewport.** Two primitives are scroll-immune, and neither moves what the user is looking at:

| Read | Scroll-immune? | Use it for |
|---|---|---|
| `read-screen --surface <id>` | **no** — follows the user's scroll | nothing you will decide on |
| `read-screen --surface <id> --scrollback --lines <n>` | **yes** | anything a CLI read can answer |
| `cmux rpc terminal.replay '{"workspace_id":…,"surface_id":…,"anchor":"screen"}'` | **yes** | when you need STRUCTURE (styles, cursor, row spans) rather than text |

`anchor:"screen"` pins the render grid to the live primary screen; the default `"viewport"` follows the scroll. It is scroll-immune by contract — cmux's `MobileTerminalRenderGridAnchorRegistry.swift` states that primary-screen scrolling never round-trips — gated on the `terminal.render_grid.screen_anchor.v1` capability, and confirmed live on 0.64.22.

Two traps around it:

- **`scrolled_rows` in the reply is NOT a scroll offset.** It is forced to 0 whenever the reply is `full:true`, and every reply is, so it is structurally always 0 (`MobileTerminalRenderGrid.swift:212`). Never build a scroll check on it. Detect scroll from `history_rows` growth or row-content deltas if you genuinely need to.
- **Param keys must be snake_case, and you must verify the target came back.** camelCase keys (`surfaceId`) are silently dropped and the call is resolved against the **focused** surface, returning `ok:true` with someone else's grid. Check `result.surface_id` against what you asked for before trusting the payload.

If you are stuck with a bare capture and see `Jump to bottom`, treat it as "I'm looking at a scrolled-up view," never as evidence the send failed — do **not** re-send. There is no CLI primitive that snaps a scrolled viewport to the bottom (verified against `cmux --help`, `cmux capabilities`, and the upstream `cli-contract.md`: the only scrollback verb is `clear-history`, which *clears* history and is destructive; `browser scroll*` is for the embedded browser only). `send-key page_up`/`end` go to the shell/PTY, not to the GUI's scroll region. Re-read with `--scrollback --lines <n>` instead.

Also worth knowing, because it looks like a probe and is not: **`terminal.viewport` is a SETTER.** Registering a `client_id` with `viewport_rows`/`viewport_columns` **caps the surface's grid** — a test surface went 84×289 → 37×99 and its history reflowed. `{"clear": true}` releases the cap. Do not call it to ask what the viewport is.

### Send keystrokes

```bash
cmux send --help
```

Escape sequences matter: `\n` and `\r` send Enter; `\t` sends Tab. **Against a shell**, if a command should actually execute, append `\n` — otherwise you're just typing into the prompt. **Against a live TUI/Ink REPL (`claude`) the `\n` does not submit at all** — see [a trailing `\n` does not submit into a TUI/Ink REPL](#gotcha-a-trailing-n-does-not-submit-into-a-tuiink-repl) below before sending into one. And because that interpretation runs on your argument regardless of target, a payload whose *content* carries the two characters `\n`, `\r`, or `\t` is rewritten in transit — see [cmux rewrites a literal backslash-n in your payload](#gotcha-cmux-rewrites-a-literal-backslash-n-in-your-payload).

**Always verify after `send` that execution started — not just that the send succeeded.** `cmux send` returns success when bytes are delivered to the PTY; it has no opinion about whether the remote shell did anything with them. Against an **agent REPL**, `workspace.prompt.submitted` is the authoritative check and also measures what arrived ([references/events.md](events.md)); against a **shell**, `read-screen` is the check, because a shell command produces no event. Concrete failure mode: if you `send` into a freshly-created surface before its shell has finished initializing, the trailing `\n` gets swallowed by the shell's startup output and the command sits at the prompt unexecuted. Exit code 0, nothing happened. (That is a *shell-startup* race, fixed by waiting for the PTY. A live TUI REPL produces the identical "exit 0, nothing happened" symptom from a different cause that waiting will never fix — see the [gotcha below](#gotcha-a-trailing-n-does-not-submit-into-a-tuiink-repl).) The only way to know is to read the screen back and look for evidence the command ran (output, new prompt line, process spinning). See the [default recipe](opening-surfaces.md#default-principle-make-new-work-visible-to-the-user) for the wait-for-PTY pattern, and Troubleshooting for the `Terminal surface not found` variant. **Caveat:** the read-back only proves anything if it reflects the *live* bottom, so take it with `--scrollback --lines <n>` — a bare `read-screen` follows the user's scroll and hands you a stale capture (see [read-screen returns the scrolled viewport](#gotcha-read-screen-returns-the-scrolled-viewport-not-the-live-bottom) before concluding nothing happened).

#### Gotcha: a trailing `\n` does not submit into a TUI/Ink REPL

**The `cmux send --help` output states the rule unconditionally — "Escape sequences: `\n` and `\r` send Enter." That sentence is wrong for a TUI/Ink REPL** (Claude Code, and anything else reading input via bracketed paste); it holds only against a shell. Trust this section over the help output when the target is a REPL. cmux is describing the bytes it writes to the PTY, not what the program on the other end does with them. A shell reads the PTY byte-by-byte, so CR is a submit. An Ink REPL receives the whole payload wrapped in a bracketed paste and treats everything inside it as *content* — so your `\n` lands as a **literal line break in the input box, and nothing submits** (stored as CR, `0x0D`, not LF). Verified live against Claude Code v2.1.216 and re-verified on 2.1.221 / cmux 0.64.20: a ~124 B two-line payload with a trailing `\n` produced **zero** user events for 10 s, and a separate `send-key Enter` then submitted it complete.

Split the rule by target:

```bash
# Shell target — one call, the \n executes it.
cmux send --workspace "$WS" --surface "$SID" "npm test\n"

# TUI/Ink REPL target (claude) — two calls, and the newline is not one of them.
cmux send     --workspace "$WS" --surface "$SID" "$MSG"    # bracketed paste: the text only
sleep 0.2                                # let the REPL finish ingesting the paste
cmux send-key --workspace "$WS" --surface "$SID" Enter     # a real key event, outside the paste — this submits
```

`send-key Enter` works precisely because it arrives as a key event rather than paste content. Keep the settle: an Enter landing mid-paste submits a *partial* message, which is worse than not submitting at all — you get a real answer to a truncated question.

**The symptom, and why it misleads.** An unsubmitted message is invisible from outside the surface. `cmux send` exits 0 (the bytes *were* delivered), and since the REPL never started a turn, no user event appears in the target session's transcript. From the caller's side that looks like the message was mangled in transit — which reads as an escaping/quoting bug in your content (backticks, `$`, quotes). For **plain text it is never the cause**: the bytes arrive intact. The one real content hazard is narrow and different — a payload containing the literal two-character sequences `\n`/`\r`/`\t`, which cmux rewrites before delivery ([next gotcha](#gotcha-cmux-rewrites-a-literal-backslash-n-in-your-payload)). Anything else: suspect the transport.

**A missing user event is not proof of non-submission either.** Text sent into a REPL that is mid-turn is *enqueued*, not dropped, and claude 2.1.221 then delivers it one of two ways: injected into the running turn at its next tool boundary as an `attachment` with `.attachment.type == "queued_command"` — in which case **no user record is ever written, even though the model reads and answers it** — or flushed as a genuine user record after that turn ends. So the transcript can show nothing for a message that already got an answer.

**How to check** — ask the event stream first; it answers directly, where the screen only hints:

```bash
SEQ=$(cmux events --snapshot 2>/dev/null | jq -r '.resume.latest_seq')   # BEFORE the send
cmux send --workspace "$WS" --surface "$SID" "$MSG"
cmux events --after "$SEQ" --name workspace.prompt.submitted \
            --limit 3 --timeout 10 --no-ack --no-heartbeat 2>/dev/null | jq -c .
```

Take the `--snapshot` seq *before* you send — it is what scopes the replay to your own submission instead of returning someone else's.

A frame means it submitted. Nothing within the timeout means it did not, and `send-key Enter` is the fix. Fall back to `read-screen` when events are unavailable (you are outside cmux, or the build predates the stream):

```bash
cmux send --workspace "$WS" --surface "$SID" "$MSG"
cmux read-screen --workspace "$WS" --surface "$SID" --scrollback --lines 80   # text still in the input box, or did a turn start?
```

Text in the box **plus a quiet REPL** (no live spinner, no `Press up to edit queued messages`) is the unsubmitted case: send `Enter` via `send-key`. Do **not** re-send the text — it appends to what's already in the box (and see the `C-c` gotcha below before trying to clear it). Text in the box with a spinner running is the *queued* case — a waiting message is drawn in the box exactly like an unsubmitted one, so screen text alone never proves non-submission, and pressing Enter there risks a double submit.

**Delivery is sporadically lossy — verify anything that matters.** Two failure modes are forensically confirmed on claude 2.1.221 / cmux 0.64.20, and **neither is size-gated**, so there is no payload size below which the check is safe to skip:

- **Fragmentation.** A single text-then-Enter send has arrived as 3–7 separately submitted turns in real traffic. It is not predictable: 12 controlled sends from 507 B to 16 KB, including 66-line multi-line payloads, fragmented **zero** times.
- **Silent byte loss.** One of those same 12 sends lost 2,538 contiguous bytes out of the middle of a 3,045 B payload — one user event, no error, the bytes provably absent from the whole transcript. A separate ~16 KB single-line send lost 3,066 bytes.

The trigger is unknown and the rate is unbounded by the data we have. `send` exiting 0 means bytes reached the PTY and nothing more, so **verify anything that matters**.

**`workspace.prompt.submitted` is the check.** It fires per submission with an exact `message_length`, so one frame whose length matches what you sent is a clean submit; a short length is the byte-loss case; several frames are the fragmentation case; no frame is a non-submit. That turns both failure modes from "warned about" into "measured":

```bash
MSG="…"; LEN=${#MSG}
SEQ=$(cmux events --snapshot 2>/dev/null | jq -r '.resume.latest_seq')
cmux send --workspace "$WS" --surface "$SID" "$MSG"; sleep 0.2
cmux send-key --workspace "$WS" --surface "$SID" Enter
cmux events --after "$SEQ" --name workspace.prompt.submitted \
            --limit 5 --timeout 15 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg ws "$WS" --argjson len "$LEN" \
      'select(.workspace_id==$ws) | {got:.payload.message_length, want:$len}'
```

Full recipe and traps: [references/events.md](events.md). Keep the nonce as a second belt when the payload is consequential — it is the only check that also survives outside cmux, where no event stream exists.

#### Gotcha: cmux rewrites a literal backslash-n in your payload

The escape scanner runs on your argument whatever the target is, so a payload whose *content* includes the two characters backslash-n — prose about escape handling, a code snippet, a Windows path — does not arrive intact. Verified byte-for-byte on cmux 0.64.20 by piping a probe into `cat > file` and diffing:

| sent | arrives as |
|---|---|
| `\n` / `\r` | Enter |
| `\t` | Tab |
| `\\` | **two** backslashes — there is no backslash escape |
| `\\n` | one backslash + Enter |
| `\qj` | literally `\qj` (only `n`/`r`/`t` are special) |

So doubling the backslash makes the corruption worse, and `--` only stops a leading dash being read as a flag. What works is denying the scanner the two-character sequence: **split the payload just after each backslash that precedes `n`, `r`, or `t`, and send the pieces back to back.** Each `send` is its own bracketed paste appending at the cursor, so the box accumulates the exact bytes (`send 'a\'` then `send 'nb'` lands `a\nb`).

`set-buffer` + `paste-buffer` also delivers verbatim, but its `--surface` resolution differs from `send`'s — a bare `surface:N` ref that `send` accepts fails there with "Surface is not a terminal" unless `--window` is also passed — so it changes targeting semantics for every caller. hotline's `cmux-reuse-surface.sh` uses the split.

### Send a single key (modifiers, arrows, ctrl-combos)

```bash
cmux send-key --help
```

Use `send-key` for `C-c`, `Up`, `Enter`, etc. Use `send` for literal text.

#### Gotcha: `send-key C-c` does not reach an in-pane Claude Code REPL

When the target surface is running **Claude Code** (the `claude` CLI in its REPL), `cmux send-key --surface <id> ctrl+c` (equivalently `C-c`) does **not** land as a working Ctrl-C inside the REPL — it neither clears half-typed input nor interrupts. Named keys (`backspace`, `Enter`, `Return`, arrows) *do* reach the REPL via `send-key`; the modifier+char `ctrl+c` form specifically does not. Verified live against Claude Code v2.1.216.

To clear or interrupt a claude REPL's prompt box, send the raw Ctrl-C byte (`0x03`) through the **text** path instead:

```bash
cmux send --workspace "$WS" --surface "$SID" $'\003'
```

That is the only path that gets a Ctrl-C into the REPL at all. (The quirk is specific to Claude Code's Ink/bracketed-paste REPL — for an ordinary shell, `send-key C-c` works fine.)

**But it is neither a reliable clear nor a safe one.** Verified on claude 2.1.221:

- At an **idle** prompt it usually clears the box — not always. It registered ("Press Ctrl-C again to exit" appeared) while leaving the previous text on screen, and in another trial a single `0x03` *restored* an earlier input into a box that had just been typed into. If you clear, **re-read the screen and require an empty box before typing.** Never assume the clear took.
- **Mid-tool-call it destroys the callee's in-flight tool call** (forensically confirmed: an interrupt record landed 82 s into a running 300 s `Bash` call).
- During the pre-tool **thinking** phase it writes no interrupt record but restores the just-submitted prompt back into the input box, so anything you then type welds onto its tail and resubmits as one corrupted turn (2/2 trials).

**Withhold the interrupt, not the message.** Sending text + `send-key Enter` into a *busy* REPL is safe — claude enqueues it and delivers it at the next tool boundary or after the turn ends. So the clear is only worth it when the box holds parked text **and** the REPL is provably quiet; parked text on a busy REPL means do something else (hotline's `cmux-reuse-surface.sh` returns a fresh-surface fallback). An empty box needs no clear at all, busy or idle.

Two things that make those judgements possible off `read-screen`:

- **`agent.hook.*` settles it without reading the screen at all.** A `Stop`/`SubagentStop` frame (`payload.phase == "completed"`) for that `surface_id` is a real turn boundary, and `PreToolUse` frames arriving means a turn is live. Prefer that over any screen heuristic; the two screen signals below are the fallback for a build or context without the event stream.
- **Busy needs two signals**, because neither holds alone: "esc to interrupt" is absent in claude 2.1.221, and the spinner's wording changes between releases — but a *running* spinner always carries a live elapsed-time parenthetical (`✶ Dilly-dallying… (5s · ↓ 124 tokens · …)`) where a finished one does not (`✻ Baked for 12s`). Corroborate with screen-byte-identity across a short window (~0.6 s) when the cost is justified. Bias both signals toward "busy" — a needless fallback beats a destroyed turn.
- **Reading the input box** has a precise discriminator: the box pads its `❯` with a NO-BREAK SPACE (U+00A0), while the transcript echoes of earlier user turns above it use a plain space. Fall back to "last `❯` line wins" on versions that don't. An untouched REPL's greyed placeholder (`Try "how does …"`) renders *inside an empty box* and `read-screen` strips the colour, so match it by shape and treat it as empty.
