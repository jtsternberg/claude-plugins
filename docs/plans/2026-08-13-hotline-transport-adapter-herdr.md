# Hotline transport adapter: cmux + herdr

**Status:** spec / design only — no implementation.
**Date:** 2026-08-13
**Tracking:** epic claude-plugins-7wze (research prereqs .1–.4, phases .5–.8)
**Goal:** let `dial.sh` drive **either cmux or herdr** as the multiplexer that hosts a callee `claude` session, cmux remaining the default and herdr an opt-in alternate for detached / remote / long-running work. Headless (`claude -p`) stays as the universal fallback.

Source of truth for the current mechanics: `plugins/hotline/skills/dial/scripts/*` and `plugins/hotline/scripts/repl-state.sh`. Everything below is measured against that code, not the work-order summary.

---

## 1. What the transport actually is today

`dial.sh` is pure orchestration — identity, resolution, cache, launch, boot-wait, delivery, cleanup — and it already carries a `TRANSPORT` variable with two values: `cmux` and `headless`. The transport is not one function; it is a **sequence of discrete operations**, each currently implemented by one script and dispatched by file-presence signals in the call dir. That sequence *is* the seam. Adding herdr means adding a third implementation of it, not rewriting `dial.sh`.

The operations, in call order, with their current cmux implementation:

| # | Operation | cmux script | What it produces / consumes |
|---|---|---|---|
| P | **preflight** — is this backend usable? | `check-cmux.sh` + `cmux-rpc.py --method system.capabilities` (must list `terminal.paste` in `result.methods`) | sets `TRANSPORT`; degrades to `headless` with a `.fallbacks` entry |
| L | **launch** (first contact, async) | `cmux-call-async.sh` | a **call dir** with backend-signal files + `pending_paste.md`; returns immediately |
| B | **boot-wait** | `wait-for-session.sh` | blocks until the callee REPL is up; promotes `session_id_preset.txt` → `session_id.txt`; calls `register-call.sh` |
| D | **deliver** | `cmux-paste.sh` | pastes the nonce-injected prompt into the booted REPL and **proves** it landed (transcript grep, then screen) |
| F | **follow-up** (reuse live host) | `cmux-reuse-surface.sh` → `cmux-paste.sh` | delivers a raw follow-up into the surface the session already lives in, no relaunch |
| W | **wait-response** | `wait-for-response.sh` → `transcript-extract.sh` | blocks until a terminal / `AWAITING_REVIEW` STATUS for this nonce; extracts the answer |
| C | **cleanup** | `close-superseded-surface.sh`; the close inside `wait-for-response.sh` | closes a superseded host once the replacement is provably live |

Two facts about this design matter more than any single script:

1. **The call dir is already the backend-agnostic contract.** `wait-for-session.sh` and `wait-for-response.sh` detect their mode purely from which files exist: `surface_ref.txt` (surface placement) vs `workspace_ref.txt` (detached) vs neither (headless). The launcher signals the backend structurally; the waiters branch on it. cmux and headless are *already* two implementations behind one call-dir contract.
2. **The response channel is filesystem, not screen.** The primary response reader is `transcript-extract.sh`, which reads `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` and correlates on the nonce in event *data*. Screen-scraping is only the fallback. This is decisive for herdr (see §7 and §8).

---

## 2. The adapter seam

Formalize what already exists implicitly: a **backend is a set of verb scripts that read and write the shared call-dir contract.** `dial.sh` gains one dispatch dimension and otherwise keeps its exact structure.

### 2.1 The one new signal: `transport.txt`

Today the backend is inferred from `surface_ref.txt` / `workspace_ref.txt`. That is fine for two backends whose host handles are disjoint, but herdr adds a third host type (a herdr *pane/agent*) that would collide with the surface/workspace heuristic. So the launcher writes an explicit `transport.txt` = `cmux` | `herdr` | `headless` into the call dir. The waiters read it first and dispatch; the existing file-presence checks stay as the cmux/headless sub-mode discriminators. This is additive — an absent `transport.txt` means "legacy call dir, infer as today."

### 2.2 The verb contract

Each backend implements these verbs. Signature = call-dir in, call-dir out, JSON on stdout. This is the interface `dial.sh` codes against; the bodies differ per backend.

```
preflight()                 → {usable:bool, reason, degrade_to:"headless"|null}
launch(cwd, name, resume?, fork?, tools?, placement)
                            → {call_dir}          # async; writes transport.txt + host handle + session_id_preset.txt + pending_paste.md
wait_boot(call_dir, timeout)→ session_id          # blocks; promotes session id; registers call
deliver(call_dir)           → {delivered, sent, confirmed}   # nonce-injected prompt into the booted callee
follow_up(host, session, prompt_file, cwd)
                            → {call_dir} | {fallback:"fresh"} | {undelivered, call_dir, prompt_file}
wait_response(call_dir, timeout) → {session_id, response, awaiting_review?}   # exit 0/3/4/1
cleanup(host, expect_call_id)    → {closed|skipped, reason}
```

The current scripts already match this shape almost exactly — `cmux-call-async.sh` = `launch`, `wait-for-session.sh` = `wait_boot`, `cmux-paste.sh` = `deliver`, etc. The refactor is to (a) route through `transport.txt`, and (b) drop the herdr implementations of each verb alongside the cmux ones. **Recommended layout:** `skills/dial/scripts/transports/{cmux,herdr}/{launch,boot,deliver,follow_up,wait,cleanup}.sh`, with the current cmux scripts moved (not rewritten) under `transports/cmux/`. Headless stays where it is — it is the fallback, not a peer that needs the full surface/follow-up machinery.

### 2.3 What stays shared (do not fork per backend)

- `repl-state.sh` — nonce mint/inject, boot-timeout budget. The nonce protocol is cross-backend by definition.
- `transcript-extract.sh` — **the response reader is backend-independent for any local callee.** A local claude session writes the same JSONL whether cmux or herdr owns its PTY. herdr must reuse this verbatim (§8).
- `session-init.sh` / `resolve-workspace.sh` / `identity-cache.sh` — caller identity and target resolution are unchanged by transport.
- `session-cache.sh` — one generalization (§6), otherwise shared.
- `register-call.sh`, `dial-history.sh`, the switchboard — one opaque host-handle field, otherwise shared.

---

## 3. Capability matrix (per operation)

| Operation | cmux | herdr | headless |
|---|---|---|---|
| **preflight** | socket + `terminal.paste` in `result.methods` | `herdr server` reachable / `HERDR_ENV=1` | always (needs `claude` on PATH) |
| **open host** | surface (side/window) or new-workspace tab | `herdr pane split … --cwd --env` → pane id | none (background process) |
| **launch callee claude** | bare `claude --session-id …` via launch script `cmux send` | `herdr agent start <name> --kind claude --pane <id> -- <claude-args>` | `claude -p … <stdin>` |
| **boot readiness** | 3 signals: banner / input-box / transcript growth | **built into `agent start`** (blocks ~30s until detected ready) | session id appears in stream-json |
| **preset callee session id** | `--session-id` on launch script (needed for transcript path) | `-- --session-id <uuid>` passthrough *(verify)* | parsed from stream, not preset |
| **deliver prompt** | `terminal.paste` (one RPC, byte-exact, queue-aware) | `herdr agent prompt <name> --wait` (atomic submit+Enter, bracketed-paste aware) | prompt on stdin at launch |
| **delivery proof** | grep nonce in transcript, then screen | nonce in transcript **(reuse `transcript-extract.sh`)**; `agent prompt` also returns a settled state | implicit (stdin consumed) |
| **wait for answer** | poll transcript for STATUS+nonce (screen fallback) | `agent wait --until done\|blocked` as the poll gate, then STATUS+nonce parse | read `type:"result"` from stream |
| **lifecycle states** | none native — inferred from spinner/box heuristics | **native**: working / blocked / done / idle / unknown | none — process exit |
| **interrupt** | raw `0x03` byte via text path | `agent send-keys <name> ctrl+c\|esc` (validated) | kill process |
| **follow-up into live callee** | reuse surface, paste (`cmux-reuse-surface.sh`) | `agent prompt <name>` re-targets the same live agent by name | not supported (new `-p` each time) |
| **survive detach / lid / SSH-drop** | no (surface dies with window) | **yes** (herdr server owns the PTY) | n/a (no interactive host) |
| **remote host** | no | **yes** (`herdr --remote <ssh-target>`) | no (local process) |
| **visible interactive (conference)** | native side-by-side surface | user runs `herdr session attach <name>` | no |
| **superseded-host cleanup** | close surface once replacement is live | mostly **unneeded** — a follow-up re-targets the same named agent, so no host stacking | n/a |

The single sentence that captures herdr's shape: **it collapses cmux's open-surface + boot-wait + paste + poll-screen into two higher-level, agent-aware calls (`agent start`, `agent prompt --wait`), and it persists the host across disconnects.** The cost is that it is headless/detached-first — its "visible" story is *attach*, not *side-by-side in the caller's window*.

---

## 4. Backend selection logic

`dial.sh` step 3 resolves `TRANSPORT` once. Proposed precedence (first match wins), preserving constraint 1 (cmux default) and constraint 2 (headless fallback intact):

1. `--headless` / `HOTLINE_FORCE_HEADLESS=1` → **headless**. (unchanged)
2. `--transport herdr` (explicit) → **herdr**; if herdr preflight fails, degrade to **headless** with a `.fallbacks` entry (never silently to cmux — the caller asked for herdr for a reason, usually persistence).
3. `--remote <ssh-target>` present → **herdr** (cmux cannot host remotely; headless cannot either). Preflight failure here is an **error**, not a degrade — there is no local substitute for "run this on that box."
4. `HOTLINE_TRANSPORT=herdr` env + herdr preflight passes → **herdr**.
5. Otherwise → **cmux**, with the existing cmux→headless degrade chain unchanged.

**Auto-detect (`HERDR_ENV=1` / running server) is deliberately NOT a step above.** Being inside a herdr pane, or having a herdr server up, must not silently flip the default away from cmux — that violates constraint 1 and would surprise every interactive local caller. Auto-detect only *enables the option* (it is what makes preflight in steps 2–4 pass); it never *selects* herdr on its own. If we later want zero-flag herdr, gate it behind an explicit `HOTLINE_TRANSPORT_AUTO=1`, so the default is a deliberate setting, not an ambient one.

Phase 1 (see §10) narrows this further: herdr is offered **only for detached and remote placements.** A `--transport herdr` with side-by-side or conference placement is rejected with guidance until Phase 3, rather than silently downgraded.

---

## 5. The nonce / STATUS protocol per backend

This is the crux the work order flagged: *how much of the nonce/STATUS scraping survives herdr's native lifecycle states?*

**Decision: the nonce/STATUS protocol stays the single cross-backend delivery contract. herdr's lifecycle states replace the *polling*, not the *answer extraction*.**

Three reasons the STATUS+nonce contract cannot be dropped for herdr:

1. **The callee is transport-blind.** The `ringing` skill (the callee half) always emits `STATUS: WORK_IN_PROGRESS call_id=<nonce>` … `STATUS: <terminal> call_id=<nonce>`. It does not know or care which multiplexer hosts it. Changing the wait side to trust herdr's `done` state instead would leave the two halves speaking different protocols, and would fork the callee by transport — exactly what we are trying to avoid.
2. **herdr's states are coarser than hotline's semantics.** hotline distinguishes `WORK_COMPLETE` vs `AWAITING_REVIEW` (reply ready, work order *not* finished — exit 4, keep session live) vs `OUT_OF_SCOPE`. herdr's `done`/`blocked`/`idle` cannot express "step 1 of 3 reported, holding for review." The STATUS line carries a distinction the lifecycle state does not.
3. **Resume replays scrollback.** The nonce exists because `claude --resume` replays the prior transcript, so a bare STATUS regex would match a *replayed* completion. herdr `--session attach` / restore has the same replay hazard; the nonce is still what disambiguates this turn's STATUS from a prior one.

So per backend:

| Backend | Deliver | "When to read" gate | Answer extraction |
|---|---|---|---|
| **cmux** | paste nonce-injected prompt; confirm nonce in transcript | poll transcript every 2s for STATUS+nonce (screen fallback) | `transcript-extract.sh` (STATUS+nonce bracketing) |
| **herdr** | `agent prompt <name> --wait` on the nonce-injected prompt | `agent wait --until done\|blocked` — one blocking call, no 2s poll loop | **same `transcript-extract.sh`, same nonce/STATUS parse** |
| **headless** | prompt on stdin | process completion | `type:"result"` from stream-json |

What herdr *buys* is that step W stops being a busy-poll of a rendered screen and becomes one `agent wait` that returns when the lifecycle settles — then we read the transcript once and run the identical STATUS+nonce extraction. Lifecycle states also give hotline something it currently *infers* from spinner heuristics in `repl-state.sh`:

- herdr `blocked` ⇒ the callee is waiting on input (permission gate, or a genuine question). Today cmux detects the post-interrupt "what should Claude do instead?" state by string-matching; herdr reports it directly. Map `blocked` (with no terminal STATUS yet) → the caller's "needs the human" signal, distinct from a timeout.
- herdr `done` + no STATUS-for-our-nonce in transcript ⇒ the callee finished a turn without emitting our terminal STATUS. That is the herdr analogue of cmux's preemption/`agent_prompt_stalled` case — surface it as "reply may be ready but unmarked; read the transcript" rather than blocking to timeout.
- `agent prompt` returning `agent_prompt_stalled` (~5s no state change) ⇒ do **not** treat as failure; a callee thinking silently is normal. Fall back to the same patient `wait_response` the cmux path uses.

Net: the nonce protocol is **not** made redundant by herdr; it is made cheaper to wait on. Keep it backend-agnostic; let herdr's states drive the gate and enrich the "why is it not done" reporting.

---

## 6. Identity & session-cache implications

Two identities are in play and only one changes.

- **Caller identity** (`MY_SESSION_ID`) — the *caller's* claude session id, resolved by `session-init.sh` from `$CLAUDE_CODE_SESSION_ID`. Transport-independent; unchanged. (herdr injects `$HERDR_*` env, but that identifies the *pane*, not the claude session — do not confuse them.)
- **Callee session id** (`.remote_session_id`) — the callee's claude session UUID. **Must stay a claude session id, not a herdr agent name**, because the whole filesystem response channel (`transcript-path.sh` → `~/.claude/projects/<cwd>/<session>.jsonl`) depends on it. This requires that `agent start … -- --session-id <uuid>` passthrough works so we can preset it exactly as cmux does (open question O1). If herdr will not let us preset the session id, Phase 1 must derive it another way (parse `agent get`/`agent read`, or read the newest transcript under the cwd) before the transcript reader can run — a real risk to flag.

**Session cache (`session-cache.sh`).** Today it stores `session_id` (claude) + `surface_ref` (an opaque cmux host handle) + `last_call_id`. The `surface_ref` key already documents itself as "opaque handle." Generalize its *meaning* without renaming it (backward compat): for herdr it holds the **herdr agent name** (the durable re-target key), optionally with the pane id. Add nothing if we can avoid it; the follow-up path just needs "the durable handle to re-address this live callee," and `agent prompt <name>` needs only the name.

Consequences that fall out cleanly:

- **Follow-ups get simpler on herdr.** cmux's `cmux-reuse-surface.sh` exists to avoid stacking N surfaces over N turns, with elaborate box-state gating before it dares paste. herdr's named agent *is* the durable session — `agent prompt <name>` re-targets it with no surface to resolve, no box to clear, no Ctrl-C hazard. The follow-up verb for herdr is nearly trivial. The one thing it must still do is mint a fresh nonce per turn (scrollback replay hazard is identical).
- **Superseded-host cleanup mostly evaporates.** `close-superseded-surface.sh` exists because a cmux follow-up that had to open a *new* surface orphaned the old one. herdr follow-ups never open a new host, so there is normally nothing to close. Keep the cleanup verb in the contract (Phase 3 conference/attach may need it) but expect herdr's implementation to be a near-no-op.
- **Persistence changes the cache's lifetime assumptions.** A cmux surface dies with its window; a herdr agent survives detach/lid/SSH-drop. A cached herdr handle is therefore valid *longer* and across events that would have invalidated a cmux one. The follow-up path must still probe liveness (`agent get <name>` / `agent list`) before addressing it, because "survives detach" is not "survives forever."

---

## 7. The alt-screen read caveat

herdr's own docs warn: a TUI on the **alternate screen** is not in scrollback, so `herdr pane read --source visible|recent` will not see it — the suggested fallback is "have the agent write its reply to a temp .md and read the file." **The claude REPL is exactly such a full-screen alt-screen TUI.** Taken naively, this looks like a blocker: hotline's whole cmux response path is "read the screen."

It is not a blocker, for two independent reasons, and the spec leans on both:

1. **Use the agent layer, not raw `pane read`.** herdr's `agent read` / `agent get` are purpose-built for driving agents like claude and use screen/lifecycle *detection* rather than raw scrollback. They are the right primitive for a claude REPL; `pane read` is for shell panes. The adapter must never call raw `pane read` against a claude agent pane.
2. **The response channel is the transcript file, not the screen — and it always was.** hotline already prefers `transcript-extract.sh` reading the JSONL on disk; screen-scraping is the *fallback* for when the transcript path can't be derived. For a **local** herdr callee the transcript file is on the same filesystem, so `transcript-extract.sh` works **unchanged** and the alt-screen caveat never bites. herdr's "write reply to a temp .md" fallback is redundant for us — claude already writes a structured transcript we know how to read.

The caveat *does* bite in one place: **remote herdr (`--remote <ssh>`).** The callee's transcript then lives on the remote box, out of reach of a local `transcript-path.sh`. Options for Phase 3 remote support: (a) `ssh <target> cat <remote-transcript>` behind a remote-transcript reader; (b) fall back to herdr's own `agent read` over the wire; (c) the temp-.md convention as a last resort. Flag this as the one place the caveat has real teeth (open question O5).

---

## 8. Why the transcript reader is the linchpin

Worth stating once plainly, because it drives the whole herdr design: `transcript-extract.sh` is **already transport-independent for local callees.** It reads a file path derived from `(cwd, session-id)` and greps event data for the nonce. Nothing in it knows about cmux. So the moment herdr can (a) host a local `claude` with (b) a session id we can derive and (c) the nonce delivered into it, the *entire* answer-extraction half of hotline — STATUS bracketing, `WORK_IN_PROGRESS` reset, `AWAITING_REVIEW` (exit 13/4), preemption (exit 12/3) — comes along for free, byte-identical to cmux. The herdr backend's real surface area is therefore small: **launch, boot-detect (mostly free), deliver, and the wait-gate.** Everything downstream is shared.

This is also why the answer to "does herdr let us drop the nonce scraping?" is *no, and we don't want it to* — the nonce reader is the single biggest piece of shared, backend-agnostic value in the system.

---

## 9. Open questions (verify before/while building)

- **O1 — session-id passthrough.** Does `herdr agent start --kind claude … -- --session-id <uuid> --allowedTools=<…> --dangerously-skip-permissions` pass those flags to the underlying `claude`? The transcript-path derivation (§6) depends on presetting the id. If not, how do we learn the callee's session id early?
- **O2 — readiness vs our session.** `agent start` blocks until *an* agent is detected ready (~30s). Does that guarantee the specific session we launched is up and its input box is drawn (the thing `wait-for-session.sh` signal C proves), or just that a claude process started? A paste into a not-yet-ready REPL is the one failure cmux went to great lengths to prevent.
- **O3 — `agent prompt --wait --until` mapping.** Does `--until done`/`blocked`/`idle` settle reliably for a callee that emits the ringing protocol, and does `agent_prompt_stalled` (~5s) fire on a callee merely thinking? Need the state timeline for a real ringing exchange.
- **O4 — resume / re-target semantics.** For follow-ups, is `agent prompt <name>` into the persisted agent always correct, or is there a case needing `claude --resume`? Confirm named agents survive the events we care about (detach, lid, SSH-drop) *and* that `agent get`/`list` reports liveness we can trust.
- **O5 — remote transcript access.** For `--remote`, where does the callee transcript live and how do we read it locally (§7)? This gates whether Phase 1 includes remote or only local-detached.
- **O6 — `--dangerously-skip-permissions` under herdr.** Unattended hotline calls need it (same trust decision as cmux, `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS`). Does herdr's `blocked` state cleanly report a permission gate when it is *off*, so we can tell the caller "it's waiting on a human"?
- **O7 — model / tools passthrough.** `HOTLINE_CLAUDE_MODEL`, the allowed-tools list — same passthrough concerns as O1.
- **O8 — payload privacy.** cmux went to lengths to keep work orders off argv (readable via `ps`). Does `agent prompt "<text>"` put the payload on a command line? If so, prefer a file/stdin form, or accept the exposure only for herdr and document it.
- **O9 — conference / attach.** Is `herdr session attach <name>` an acceptable "hand this to the human" story for Phase 3, given it is attach-in-place rather than a side-by-side pane in the caller's existing window?

---

## 10. Phased rollout

Additive throughout. cmux behavior is untouched until Phase 3 touches shared files, and each phase ships independently.

**Phase 0 — seam groundwork (no herdr, no behavior change).**
Introduce `transport.txt` into the call dir and route `wait-for-session.sh` / `wait-for-response.sh` dispatch through it (falling back to today's file-presence inference when absent). Move the cmux scripts under `transports/cmux/` unchanged. Prove `bash tests/run-all.sh` is byte-for-byte green — this phase must be provably inert.

**Phase 1 — herdr for detached + (optionally) remote work orders.**
The minimal viable backend: `--transport herdr` accepted **only** for `--placement detached` (and `--remote` if O5 lands cleanly). Implement `preflight`, `launch` (`pane split` + `agent start --kind claude`), `boot` (lean on `agent start`'s built-in readiness, plus signal C if O2 requires it), `deliver` (`agent prompt --wait`, nonce-injected). **Reuse `transcript-extract.sh` verbatim** for `wait_response`; use `agent wait --until` only as the poll gate. No follow-ups, no conference, no side-by-side. Selection precedence steps 2–4 from §4, restricted to detached/remote. Ship it as the "long-running / survives-disconnect work order" transport, which is the concrete thing JT wants first.

**Phase 2 — follow-ups + AWAITING_REVIEW on herdr.**
Generalize `session-cache.sh`'s `surface_ref` to hold the herdr agent name (§6). Implement the herdr `follow_up` verb (`agent prompt <name>`, fresh nonce, liveness probe via `agent get`). Wire `blocked`/`done`-without-STATUS into the caller's reporting so a herdr callee at a review checkpoint (exit 4 / `AWAITING_REVIEW`) and a permission-gated callee (`blocked`) are distinguished from a timeout. Keep the `cleanup` verb a documented near-no-op for herdr.

**Phase 3 — remote transcript, conference, and (guarded) auto-detect.**
Land the remote-transcript reader from O5 so `--remote` gets full structured response extraction. Add conference via `herdr session attach` (§O9). Optionally add `HOTLINE_TRANSPORT_AUTO=1` (explicit opt-in only) so `HERDR_ENV=1` can *select* herdr, never as an ambient default. Revisit whether any of the cmux surface-cleanup complexity can be retired now that a persistent-host model exists alongside it.

---

## 11. Constraint check

1. **cmux stays default.** ✅ §4 keeps cmux as the fall-through; herdr requires an explicit flag/env; auto-detect only enables, never selects.
2. **Headless fallback stays.** ✅ Untouched; remains the universal degrade target (and the explicit-herdr degrade target for non-remote).
3. **Stable wrapper contract.** ✅ `.status` / `.call_dir` / `.remote_session_id` unchanged; the opaque host handle keeps the `surface_ref` key; `transport.txt` is internal to the call dir, not part of the emitted JSON. One JSON object out, same statuses/exit codes.
4. **Additive & phased.** ✅ Phase 0 is provably inert; Phase 1 delivers the detached/remote work-order case JT wants first; nothing is a big-bang rewrite.
