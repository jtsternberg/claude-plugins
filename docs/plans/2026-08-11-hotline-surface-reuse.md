# Hotline follow-up dials stack orphaned surfaces

Epic: claude-plugins-ma0b. Phase 1 — investigation and proposal. No behavior changed yet.

A caller dials a work order, the callee checkpoints `AWAITING_REVIEW`, and the caller's
follow-up opens a **second** pane resuming the same session instead of typing into the live
one. The first pane is left running a superseded REPL, and the caller's payload reports
`fallbacks:[]` — no signal that anything degraded.

## Findings

### F1 — The multi-line guard is the cause

`dial.sh:457`:

```bash
if ! $FIRST_CONTACT && [[ "$TRANSPORT" == "cmux" && -n "$SURFACE_REF" && "$MESSAGE" != *$'\n'* ]]; then
```

`*$'\n'*` rejects **any** message containing a newline. Work-order follow-ups are
essentially always multi-line, so the reuse path — the thing that exists to stop surface
stacking — is dead in exactly the case it was built for. The comment above it explains the
reasoning honestly: reuse types the message into the live REPL via keystroke simulation,
while the fresh path hands the prompt to a launch script as an argument, so the guard was
avoiding keystroke fragility. It avoided it by never running.

Evidence, same remote session `dee93a9e-436e-412b-82ae-f90ff81d20c4`, same workspace
`300963EA-FCC5-415D-A359-7E57C673EA11`, same pane `41EAFE7D-DF21-41BF-8722-3F8C245D7978`:

| call dir | surface | contact |
|---|---|---|
| `/tmp/hotline-call-49CD5` | `2D56ABF6-…` (surface:210) | first |
| `/tmp/hotline-call-9c9oJ` | `12798FEB-…` (surface:211) | follow-up |

Two surfaces, one session. Both are tabs in one pane, which is why long exchanges read as a
pile of near-identical tabs rather than as separate work.

### F2 — Nothing ever closes the superseded surface

`claude --resume` in the new surface takes over the session; the old surface keeps a REPL
that will never be spoken to again. No code path closes it. N follow-ups leave N−1 zombies.

### F3 — A skipped reuse records nothing

`add_fallback "surface-reuse→fresh(...)"` sits at `dial.sh:471`, *inside* the block the
guard skipped. When the guard bails there is no fallback entry at all, so the payload is
indistinguishable from a clean first-contact dial. Confirmed by the observed
`fallbacks:[]`.

### F4 — Stale `surface_ref` is never cleared (new, latent)

`dial.sh:603-607` refreshes the cached `surface_ref` only when a new one exists:

```bash
bash "$DIAL_SCRIPTS/session-cache.sh" update … ${SURFACE_REF:+--surface "$SURFACE_REF"}
```

and `session-cache.sh:115` treats an empty `--surface` as "leave untouched". Two follow-up
outcomes produce no surface: the cmux→headless fallback (`dial.sh:560`), and side placement
degrading to detached (`dial.sh:580`, signalled by `workspace_ref.txt` with no
`surface_ref.txt`). Both leave the **previous** surface in the cache. The next follow-up
then passes the reuse guard and types into a surface the session no longer occupies — the
message lands in a zombie REPL and the response never comes from where the waiter is
looking. Same hole on the conference path (`dial.sh:526`).

### F5–F7 — cmux surface-close semantics (probed live)

Probed in a throwaway workspace `hotline reuse probe` (created, used, closed; no stray
processes left — teardown verified):

- **`close-surface` needs `--workspace` even with a surface UUID.** `cmux close-surface
  --surface <uuid>` returns `Error: Surface not found: <uuid>` for a surface that plainly
  exists — `read-screen --surface <same-uuid>` works fine in the same breath. Same for
  `new-surface --pane <uuid>` → `Error: not_found: Pane not found`. Adding `--workspace
  <ws-uuid>` makes both succeed. The error wording is a lie; it means "not resolvable in
  the current workspace context".
- **Closing a surface kills its foreground process.** A `sleep 400` running in the closed
  surface was reaped. So closing a superseded pane does terminate the REPL in it — which is
  the point, and also why the safety checks below are not optional.
- **cmux refuses to close the last surface**: `Error: invalid_state: Cannot close the last
  surface`. The worst case of an over-eager cleanup is a clean refusal, not a destroyed
  workspace.
- A surface's workspace UUID is derivable without a cache change:
  `cmux tree --all --json --id-format uuids`, find the workspace whose
  `panes[].surface_ids` contains it.

### F8 — Multi-line delivery works, but the transport is not trustworthy for payloads

A 190-byte, 6-line payload with `$`, backticks and quotes went through `cmux send` +
`send-key Enter` into a live PTY and arrived **byte-identical**. So multi-line reuse is
mechanically possible today.

It is still the wrong thing to bet a work order on. `cmux-cli`'s own verified record (claude
2.1.221 / cmux 0.64.20) documents two failure modes on this exact path, neither size-gated:
a single send arriving as 3–7 separately submitted turns, and **silent loss of 2,538
contiguous bytes out of a 3,045-byte payload** — one user event, no error, bytes provably
absent from the transcript. A truncated work order is the most expensive possible failure
here: the callee acts, confidently, on instructions that lost their middle.

### F9 — Conference follow-ups share the defect

Step 5a runs before 5b, so a conference follow-up hits the same guard, then opens a second
surface at `dial.sh:490`. The `session-cache.sh update --surface` at 526 keeps the cache
pointing at the newest surface, so the sprawl is identical — one extra tab per exchange.

### F10 — Side notes filed, not fixed here

- `do_detached()` stores a **positional** `workspace:N` ref in `workspace_ref.txt`
  (`cmux-call-async.sh:296-298`) while the surface path deliberately stores UUIDs, keeping
  the retargeting hazard the surface path fixed — claude-plugins-3paw.
- Follow-ups carry no `[MODE:]`/`[SESSION:]` tags, so `persist-call-meta.sh` writes no
  `mode.txt`/`caller_session.txt`, `register-call.sh` exits early, and **dial history
  records only first contact** — claude-plugins-38xm. Visible in the evidence:
  `/tmp/hotline-call-9c9oJ` has no `caller_session.txt`.

## Recommendation

Land **A2 + C + F4 fix**, then **B** as defense in depth. Ranking:

| Rank | Direction | Why |
|---|---|---|
| 1 | **A2** — payload to the call dir, one-line nudge into the REPL | Removes the cause. Reuses the already-proven single-line send path verbatim, so it adds **no** new transport risk, and the payload never crosses a lossy hop at all. claude-plugins-i8fb |
| 2 | **C** — always record the skip | Independently landable, tiny, and turns a silent degradation into a reported one. claude-plugins-6nbr |
| 3 | **F4** — clear a stale `surface_ref` | Small, and it stops A2 from confidently typing into a zombie. claude-plugins-2caw |
| 4 | **B** — close the superseded surface | Still worth having, but A2 shrinks its scope sharply (see below). claude-plugins-n7xo |
| — | **A1** — type the multi-line message in directly | Rejected. Mechanically works (F8) but stakes a work order on a transport with documented, unexplained mid-payload byte loss. |

**Why B drops to fourth.** Once A2 lands, a follow-up only opens a fresh surface when reuse
genuinely refuses — and the refusal reasons are mostly "the old surface is busy, parked
mid-turn, or interrupted", i.e. exactly the states where closing it would destroy live work.
The remaining closeable case is the idle-but-unusable surface, plus the backlog of zombies
already created. Real, but narrow. It must be conservative, and it must never be the thing
that makes A2 safe.

## Exact behavior changes

### A2 — `cmux-reuse-surface.sh` + `dial.sh`

`cmux-reuse-surface.sh`:

1. Accept `--prompt-file <path>` alongside `--prompt`, so the payload never rides argv.
2. Decide delivery by payload shape:
   - **single-line and ≤ 800 bytes** → unchanged inline behavior (today's proven path; keeps
     the follow-up text in the callee transcript where the switchboard can read it).
   - **otherwise** → write the payload verbatim to `$CALL_DIR/message.md` and type exactly
     one line:
     ```
     [CALL_ID: <nonce>] Next instructions: read <call_dir>/message.md in full before acting. (Preview: <first ≤160 chars>…)
     ```
     Instruction before preview, deliberately — a preview read as the whole task is the one
     way this design fails. The nonce travels in the nudge, so
     `wait-for-response.sh`'s existing nonce submit-confirmation covers it unchanged.
3. Keep `split_for_cmux_send` on the nudge: a preview can contain a literal `\n`.
4. After the Enter, poll `read-screen` for ~2s for the nonce; if it never appears, `rm -rf`
   the call dir and return `{"fallback":"fresh","reason":"nudge did not land"}` rather than
   leaving `wait-for-response.sh` to fail at its submit deadline 30–60s later.

`dial.sh`:

5. Drop `"$MESSAGE" != *$'\n'*` from the step-5a guard (`dial.sh:457`).
6. Pass `--prompt-file "$PROMPT_FILE"` through when the caller supplied one; otherwise write
   `$SEND_PROMPT` to a temp file and pass that.

`plugins/hotline/skills/ringing/SKILL.md`:

7. Carve-out under Workspace Isolation: **files under the hotline call dir
   (`/tmp/hotline-call-*`) are call transport, not workspace content** — reading one when a
   nudge points at it is expected and is not a violation. Scoped to that prefix only;
   everything else in that section stands. Without this the callee is told to obey two rules
   that contradict each other, which is the exact bug that killed callee-side logging
   (`register-call.sh` header).

### C — every skip reports

Restructure the step-5a guard so no bail is silent:

```bash
if ! $FIRST_CONTACT && [[ "$TRANSPORT" == "cmux" ]]; then
  if [[ -z "$SURFACE_REF" ]]; then
    add_fallback "surface-reuse-skipped(no-cached-surface)"
  else
    …attempt reuse; on refusal keep today's surface-reuse→fresh(<reason>)…
  fi
fi
```

Document both strings in the dial `SKILL.md` fallback list (currently `SKILL.md:91-95`).
Note for the reviewer: the work order asked for `surface-reuse-skipped(multiline)`, and if C
lands **before** A2 that is the right string. After A2 there is no multiline skip left —
multi-line is delivered, not refused — so the surviving skip reason is
`no-cached-surface`. If you want C first as a standalone, say so and it ships with both.

### F4 — clear, don't just refresh

`session-cache.sh`: add `--clear-surface`, which deletes the `surface_ref` key (distinct
from today's empty `--surface`, which means "leave untouched" and must keep meaning that).

`dial.sh`: at step 6, and on the conference path, when a follow-up ends with no surface
(headless fallback, or `workspace_ref.txt` present with no `surface_ref.txt`), call
`update --clear-surface`.

### B — close the superseded surface

After step 6 succeeds (so the replacement is provably live), when a follow-up opened a new
surface and the cache held a different one:

1. `session-cache.sh` also records `last_call_id` on `set`/`update`.
2. Require **all** of: old surface still readable; its scrollback contains the previous
   exchange's `last_call_id` (proof it is the superseded hotline exchange and not a tab the
   user repurposed); `repl_looks_busy` false on two reads ~0.6s apart; not
   `repl_is_interrupted`.
3. Resolve its workspace UUID via `cmux tree --all --json --id-format uuids` (F5), then
   `cmux close-surface --workspace <ws-uuid> --surface <old-uuid>`. **Never by tty** — cmux
   recycles tty numbers.
4. Record `surface-cleanup→closed(<old>)`, or `surface-cleanup-skipped(<reason>)` for every
   bail, including cmux's `Cannot close the last surface` refusal.
5. `HOTLINE_CLOSE_SUPERSEDED=0` opts out. Default on — JT asked for the cleanup explicitly.

The busy/idle helpers (`input_box_content`, `repl_looks_busy`, `repl_is_interrupted`) live in
`cmux-reuse-surface.sh` today and are needed in two places once B exists. Per the repo's
sharing rule they move to `plugins/hotline/scripts/` and get sourced from
`${CLAUDE_PLUGIN_ROOT}` — the transcript parser has already been duplicated twice in this
repo and drifted both times.

## Test plan

TDD: each behavior gets a failing test first. Every new suite carries the poison-stub guard
from `fix-hotline-test-pane-leak` (`deec8d9`) — `cmux` and `claude` stubbed at the front of
`PATH`, a violations log, and a final assertion that nothing reached the real binaries. No
suite opens a real cmux surface; the prior-art branch exists because one leaked a live
`claude --resume` pane on every run.

`plugins/hotline/tests/cmux-reuse-surface_test.sh` (extend):
- Multi-line payload → `message.md` written byte-identical to the input, and **exactly one**
  `send` chunk goes out, containing no newline.
- The nudge contains the nonce and the `message.md` path; preview truncated at 160 chars;
  instruction precedes preview.
- Single-line ≤ 800 B → inline path unchanged (pins the existing behavior against
  regression).
- `--prompt-file` and `--prompt` produce identical delivery for the same bytes.
- Nonce never appears on screen → `{"fallback":"fresh"}` and the call dir is removed.

`plugins/hotline/tests/dial_wrapper_test.sh` (extend):
- Multi-line follow-up now **takes** the reuse path (stubbed `cmux-reuse-surface.sh`
  returning a `call_dir`); no new surface is opened.
- Follow-up with no cached surface → `fallbacks` contains
  `surface-reuse-skipped(no-cached-surface)`.
- Follow-up that falls back to headless → cache `surface_ref` is **gone**, not stale.
- Follow-up whose side placement degrades to detached (`workspace_ref.txt`, no
  `surface_ref.txt`) → same.

`plugins/hotline/tests/session-cache_test.sh` (new): `--clear-surface` removes the key;
empty `--surface` still leaves it untouched; `last_call_id` round-trips.

`plugins/hotline/tests/surface-cleanup_test.sh` (new): closes only with nonce-match + idle;
skips on busy, on interrupted, on nonce absent, on unreadable; the close command carries
`--workspace` and a UUID (asserted against the stub's arg log); `Cannot close the last
surface` becomes a recorded skip, not an error; `HOTLINE_CLOSE_SUPERSEDED=0` disables it.

Gate: `bash tests/run-all.sh` green with `skipped 1` (`codex: live-plugin`) unchanged. New
suites match the discovered-by-glob paths, so the runner picks them up without edits.

## Open questions

1. **Inline threshold.** Proposing single-line and ≤ 800 B stays inline. 507 B has been
   observed clean; loss showed up at 3,045 B and 16 KB. Prefer a flat "always use the file
   for follow-ups" instead? It is simpler and strictly safer, at the cost of every follow-up
   body leaving the callee transcript (see 2).
2. **Switchboard readability.** With nudge delivery the dashboard shows "read this file"
   where the question used to be. Filed as claude-plugins-9vzb (inline `message.md` when a
   turn is a nudge). Blocker for A2, or a follow-up?
3. **B on by default?** Proposing yes, with `HOTLINE_CLOSE_SUPERSEDED=0`. It kills a REPL
   process (F6), so the opposite default is defensible.
4. **Existing zombies.** B only cleans up going forward. Worth a one-shot sweep that closes
   idle hotline surfaces whose session is cached elsewhere, or leave them to the user?
5. **C's string, if it ships first** — see the note under C.

## Phase 2 — what landed

Approved in the order C, F4, A2, B. All four are on `hotline-surface-reuse`.

| Unit | Commit | Notes |
|---|---|---|
| C — every skip reports | `dcf3427` | Plus the fallback table in the dial SKILL.md. |
| F4 — clear a stale `surface_ref` | `dcf3427` | `--clear-surface`, distinct from an empty `--surface`; also records `last_call_id`. |
| A2 — nudge delivery | `3617572` | Inline stays for single-line ≤ 800 B; larger goes via `message.md`. |
| B — close the superseded surface | `b9d0314` | Four-condition gate, `HOTLINE_CLOSE_SUPERSEDED=0` opt-out. |
| Durable record + switchboard | `1083c46` | Merge-bar item. |

**The durable record** is `~/.agents-hotline/exchanges/<call_id>.md`, written at
delivery time with an `index.jsonl` (call_id, timestamp, session, cwd, bytes,
delivery mode). It sits outside the call dir because the call dir is transient,
and it is keyed by the nonce the callee echoes on every STATUS line. The
switchboard resolves a pointer through live call dir → archive → the pointer's own
text, and marks resolved entries `via file`. Inline payloads are not archived —
they are already durable in the callee's transcript, which is why they stay inline.

Two things the reviewer's design notes changed from the proposal above: the
inline/file split is threshold-based rather than always-file (quick exchanges stay
readable in the transcript), and cleanup is default-on.

Answers to the open questions are in the approving review; nothing above is left
undecided.

### Deferred

- **claude-plugins-9rzn** — manual sweep for zombie surfaces already accumulated.
  Filed rather than built, with the caller's authorisation: it is the lowest-value
  unit and was not worth risking the rest.
- **claude-plugins-38xm** — follow-up exchanges still never reach dial history. The
  archive covers the payload; the history entry does not exist either way.
- **claude-plugins-86ka** — found while debugging this: every launch script passes
  the full prompt as argv, so `ps` exposes complete work orders to any local
  process. Follow-ups no longer do this; first contact still does.
- **claude-plugins-3paw** — `workspace_ref.txt` still stores a positional ref.

## STATUS

Phase 2 complete for the four approved units. Awaiting review.
