# Hotline delivery rework: terminal.paste over the control socket

**Status: design for review — nothing built.** Replaces the nudge + `message.md` sidecar delivery on the reviewed-but-unmerged `hotline-surface-reuse` branch (HEAD a9b5388) with cmux's `terminal.paste` RPC, spoken directly over the control socket so payloads never touch argv. Merge of anything remains JT's call.

## Evidence base (all durably recorded)

| Finding | Where proven | Record |
|---|---|---|
| `terminal.paste` byte-exact 12/12 incl. 16KB | phase-1 probe, `/tmp/hotline-paste-probe/` | claude-plugins-jtti, -6070 |
| No fragmentation: 17/17 submitting trials land as ONE user turn (return, ctrl+enter, none+Enter); 75/75 markers every time | phase-2 probe, `/tmp/hotline-paste-probe-phase2/` | claude-plugins-gxar (closed) |
| Mid-turn paste queues intact, lands as one `queued_command` **attachment** (no user turn written) | phase-2 test (c) | gxar |
| Short nonce visible on screen pre-submit; large paste collapses to `[Pasted text +N lines]` placeholder | phase-2 test (d) | gxar |
| `cmux rpc` CLI is argv-only — no stdin/`@file`/env params | phase-2 test (e) + source (`cmux.swift:19845`) | gxar, 86ka |
| Control socket: unix socket at `$CMUX_SOCKET_PATH` (0600), newline-delimited JSON `{"id","method","params"}` → one-line `{"id","ok",...}`; 256KB single-line requests accepted; `terminal.paste` in advertised methods | live probe + `manaflow-ai/cmux` source (`CmuxControlSocket` Wire/Server) | claude-plugins-86ka comment |
| Original 2,538/3,045-byte send loss was libxev ordered-write bug, fixed upstream #9093, in installed 0.64.22; residual send loss = kernel cooked-tty overflow, not cmux | prior research | jtti |

Not yet exercised: the **raw-socket `terminal.paste` hop itself** (probes used the CLI; the socket write is byte-identical to what the CLI sends, but that final combination is unverified). First build step below closes this.

## The delivery verb

One shared helper at the plugin root (both dial and future callers use it):

`plugins/hotline/scripts/cmux-rpc.py` — python3 stdlib only:

1. Read payload from a **file path argument** (never argv, never env).
2. Build `{"id":<uuid>,"method":"terminal.paste","params":{"text":<payload>,"workspace_id":<uuid>,"surface_id":<uuid>,"submit_key":"return"}}`; `json.dumps` escapes newlines in-process.
3. Socket resolution: `$CMUX_SOCKET_PATH` → `~/.local/state/cmux/last-socket-path` contents → `~/.local/state/cmux/cmux.sock`.
4. Prepend capability envelope `_cmux_capability_v1 $CMUX_SOCKET_CAPABILITY <line>` when that env var is present (needed only for non-descendants of the cmux app; hotline callers inside cmux terminals are covered by ancestry auth).
5. Write line + `\n`, read one response line, emit it as JSON on stdout, exit nonzero on `ok:false`/timeout.

`submit_key:"return"` (phase-2: single turn every trial; cmux auto-upgrades return→ctrl+enter for multi-line Claude payloads anyway). Payload keeps the leading `[CALL_ID: <nonce>]` line — it's the correlation key for the session cache, close-superseded gate, and landing confirmation.

`workspace_id` resolution: same `cmux tree --all --json --id-format uuids` lookup `close-superseded-surface.sh` already does; factor it into `repl-state.sh` or a small shared function.

## Landing confirmation (replaces `nudge_landed`)

RPC `ok:true` is an ack, not delivery proof — the no-trusting-exit-codes rule stands. Two-tier check:

1. **Primary — callee transcript.** We know the callee session id (session cache) → its JSONL under `~/.claude/projects/<cwd-slug>/`. Poll (10×0.3s) for the CALL_ID nonce in either a **user turn** or a **`queued_command` attachment** (the busy-REPL shape phase-2 found; a verifier counting only user turns reads a landed queued paste as lost). Byte-definitive, immune to the `[Pasted text]` screen collapse and to scrolled viewports.
2. **Secondary — screen.** If the transcript isn't readable (cross-cwd edge, slow flush), fall back to `cmux read-screen` accepting: the nonce, `[Pasted text`, `Press up to edit queued`, or `Jump to bottom` — same acceptance set as today's `nudge_landed`, plus the placeholder.

On failure: `{"fallback":"fresh"}` with reason, exactly as the branch does now — unit C records it.

## Keep / drop / replace (vs the a9b5388 branch)

**Keep unchanged** — no coupling to the delivery verb (verified in code, not assumed):
- Unit B: `close-superseded-surface.sh` 11-check gate + `dial.sh` step 7 (fresh surfaces still happen whenever reuse refuses).
- Unit C: reuse-skip/fallback recording (`dial.sh:482-509`); only the nudge-specific *reason string* changes.
- Unit F4: `--clear-surface` + `last_call_id` in `session-cache.sh`, `register-call.sh`.
- All pre-send gates in `cmux-reuse-surface.sh`: existence, `repl_is_interrupted` refusal, parked-input double-read idle proof, conditional Ctrl-C clear.
- Boot wait, transport/placement resolution, fork-on-`--resume`.

**Replace** in `cmux-reuse-surface.sh`:
- `DELIVERY` inline-vs-nudge decision (`:249-256`), nudge construction + `message.md` write (`:260-299`), `split_for_cmux_send` + send loop + send-key Enter (`:153-167`, `:328-342`) → one `cmux-rpc.py` paste of the full payload from `--prompt-file`.
- `dial.sh:490-491`: always hand reuse a **file** (write `$SEND_PROMPT` to a 0600 temp file when the caller used `--prompt`) — closes the argv gap the branch left open (86ka).
- `nudge_landed` → the two-tier confirmation above.

**Drop entirely** (inline payloads are durable in the callee transcript — that's the point). None of this ever shipped — it exists only on the unmerged branch, and `~/.agents-hotline/exchanges/` has never been created on disk — so "drop" means it never reaches main:
- The exchanges archive: `cmux-reuse-surface.sh:96-100,274-288` (`~/.agents-hotline/exchanges/`, perms machinery included).
- Switchboard `resolveNudge` + `EXCHANGES_DIR` + `nudgeCache` + `via file` badge (`server.js:239-269,314-317,826`) → **claude-plugins-ml7l closes as moot** (the arbitrary-path read it wanted hardened is deleted).
- Ringing-skill call-dir carve-out (`ringing/SKILL.md:29`) — nothing points the callee at a file; workspace isolation becomes unconditional again.
- `INLINE_MAX_BYTES` / `PREVIEW_MAX_CHARS` knobs.

## Scope decision — both (decided)

**A. Reuse-path swap** (the core of this design): follow-up delivery via socket paste.

**B. First-contact unification.** Today first contact runs `claude "<ringing-wrapped prompt>"` — the full payload on claude's argv, which is the *original* 86ka leak, and it survives scope A. Proposal: launch a **bare** `claude` REPL, reuse the existing boot wait, then deliver the ringing-wrapped prompt through the same paste+confirm path. One delivery mechanism everywhere, 86ka actually closed, and the async launch-script prompt plumbing (`cmux-call-async.sh:212-223`) simplifies. Cost: touches the fresh path and its tests; boot-wait must gate on the input box, not just process start.

**Decided (JT, v1 review): both.** A alone would leave the leak class it set out to close; if B stalls in review, A still ships alone. (Headless transport is untouched either way; `claude -p` has no surface.)

## Capability preflight

At dial time (cmux transport only): one `system.capabilities` socket call; require `terminal.paste` in methods. Missing (old cmux) → record `terminal-paste-unavailable→fresh` fallback and take the existing fresh/async path — **no** resurrection of the send-split/nudge machinery as a fallback tier. One delivery verb, one fallback (fresh surface), consistent with "right solution, not workaround".

## Tests

Poison-stub discipline breaks for socket calls — PATH stubs can't intercept a direct socket write. New seam: suites point `CMUX_SOCKET_PATH` at a **test unix socket** served by a ~30-line python stdlib stub that logs each request line to a violations/requests file and returns canned `{"ok":...}` responses. Poison layer: default stub server answers `ok:false` with `TEST BUG: unstubbed socket call`; per-case servers override. `cmux`/`claude` PATH poison stubs stay for the CLI verbs that remain (read-screen, tree, close-surface, send-key none — actually send-key drops too).

Rework: nudge/archive test blocks (`cmux-reuse-surface_test.sh:429-645`, `switchboard_test.sh:176-230`, `dial_wrapper_test.sh:500`) delete or convert to paste-shaped assertions: full payload in one request line, `[CALL_ID:]` header present, temp file 0600 and cleaned up, transcript-poll confirmation incl. the `queued_command` shape, capability-miss fallback recorded.

## Security notes / upstream

- Ancestry auth means **any descendant of the cmux app has full unauthenticated socket control** (verified: unwrapped request accepted). Fine for hotline's threat model (JT's own machine, 0600 socket), but worth an upstream note; beads task filed.
- Upstream ask: stdin params for `cmux rpc` — consistent with `todo set`/`diff -`/`claude-hook` which already read stdin. Would let shell callers skip the python helper. Beads task filed; #3872 (`--bracketed` on paste-buffer) noted there as the stalled sibling PR worth nudging.
- Capability-token staleness (rotation policy unknown) only matters for non-descendant callers (cron/LaunchAgent) — out of scope; documented limitation.

## Build & rollout

1. **Step 0 — close the last evidence gap:** raw-socket `terminal.paste` smoke test against a throwaway REPL (the phase-2 rig, one trial each: idle-submit, busy-queue). Cheap, and the only untested combination.
2. Branch from a9b5388 (keeps B/C/F4 + their tests intact in history), build via dialed work order, adversarial review round, push. Same overnight pattern as the original branch.
3. Merge: JT's call — the rework branch alone; it supersedes `hotline-surface-reuse` totally.

## Decisions (from v1 review)

1. **Scope B is in** — first-contact delivery unifies onto paste in this rework.
2. **Old branch: keep only as a fallback pointer until the rework branch is pushed and survives adversarial review, then delete local + origin refs.** Supersession is total — the rework branches from a9b5388, so every old commit is contained in it, and no PR/review thread exists on the old ref (review was in-session). Keeping it longer buys nothing.
3. **Transcript-as-record is sufficient; no durable outbox.** The exchanges archive never shipped anyway (branch-only, never written to disk).
