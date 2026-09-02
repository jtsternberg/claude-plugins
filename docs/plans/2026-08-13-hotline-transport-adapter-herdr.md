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
3. `--remote <ssh-target>` present → **herdr** (cmux cannot host remotely; headless cannot either). Preflight failure here is an **error**, not a degrade — there is no local substitute for "run this on that box." **Phase 3 scope, gated on O5 — not shipped in Phases 0–2.** `dial.sh` parses `--remote` and refuses it outright, naming Phase 3 and, for `--transport herdr --remote`, the reason: herdr could host the callee, but its transcript would live on the remote filesystem, out of reach of the local reader every hotline answer comes from. The refusal is the point — a call that connects and can never be read is worse than one that never starts.
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
- **Callee session id** (`.remote_session_id`) — the callee's claude session UUID. **Must stay a claude session id, not a herdr agent name**, because the whole filesystem response channel (`transcript-path.sh` → `~/.claude/projects/<cwd>/<session>.jsonl`) depends on it. `agent start … -- --session-id <uuid>` passthrough works (§9 O1), so the callee's id is preset exactly as cmux does it, before the callee boots. `agent start` also reports the session id it observed; that observation is authoritative where it differs from the preset, so a passthrough regression surfaces as a recorded mismatch rather than a transcript path that misses in silence.

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

## 9. Research findings and open questions

Seven of the nine questions this spec opened are answered by the shipped stack;
the two that are not are both Phase 3 inputs and are kept under their own
heading below so they stay findable. Question IDs are stable — O5 is still O5.

### 9.1 Resolved (verified against the shipped stack)

- **O1 — session-id passthrough. RESOLVED (verified live on herdr 0.8.0).** `herdr agent start --kind claude … -- --session-id <uuid> --allowedTools=<…> --dangerously-skip-permissions` passes those flags through to the underlying `claude` verbatim, so the transcript-path derivation (§6) gets an id preset before the callee boots. `agent start` additionally reports the session id it observed, and the herdr backend treats that observation as authoritative when it disagrees with the preset — a passthrough regression then lands as a recorded mismatch instead of a transcript path that reads nothing for the whole call.
- **O2 — readiness vs our session. RESOLVED, in the negative (verified live on CC 2.1.251 / herdr 0.8.0).** `agent start`'s readiness claim does **not** guarantee a usable input box. Against a fresh `git init` directory it returned `interactive_ready:true, agent_status:"idle"` with Claude Code's startup **trust dialog** on screen — a dialog that takes keystrokes, so a payload submitted into it answers the dialog's default option (`No, exit`) and kills the callee, leaving no turn and no transcript. Readiness is therefore treated as a claim to re-establish, not a fact: first contact settles, re-polls `agent get` until herdr reports interactive-ready and not `blocked`, then reads the screen once and refuses on the trust dialog's signature. Every such refusal is `sent:false`, so the caller is free to re-dial. This is the herdr analogue of the cmux path's `--wait-box`, for the same reason — a launch-time signal is not a submit-time one.
- **O3 — `agent prompt --wait --until` mapping. RESOLVED, and it splits in two.** `agent wait <name> --until idle --until done --until blocked` is the shipped when-to-read gate, called in bounded slices (30s default) so a callee that emits its terminal STATUS mid-turn is noticed before it settles. It stays a **gate, not a verdict** — the transcript is read first on every iteration, because herdr's states cannot express hotline's `AWAITING_REVIEW`. Whether it settles *reliably* is therefore untested by construction: the gate branches on neither outcome, since a slice that times out means "still working," which is exactly what the next transcript read confirms or refutes. An unreliable settle would degrade the wait into a 30s poll rather than break it. The one state read off the reply is `blocked`, and that is re-probed before it ends a call. Separately, `agent_prompt_stalled` **does** fire on a callee merely thinking (~5s with no observed state change), which is why the submit deliberately runs *without* `--wait`: conflating "did the payload arrive" with "has the callee answered" would fail dials that worked.
- **O4 — resume / re-target semantics. RESOLVED for re-target (verified live on herdr 0.8.0).** A follow-up is just another `agent prompt` to the same live name: context continues and both exchanges land in one session and one transcript ("remember 42" → later "what number?" → "42"). A finished, unfocused agent reports `status: done` rather than `idle` and still re-accepts a prompt, so `done` is not a closed door. `claude --resume` is not merely unnecessary but incompatible — a resume cannot carry the `--session-id` preset the transcript path is derived from, so the herdr launcher refuses `--resume`/`--fork-session` and points at cmux for adopting an unrelated session id. Liveness comes from `agent get`: herdr clears a name when its agent exits, so an unresolvable name *is* the death report. The detach/lid/SSH-drop half rests on herdr's documented persistence rather than a live probe of those events — which is precisely why the follow-up path probes liveness every turn instead of trusting it, since "survives a detach" is not "survives forever".
- **O6 — `--dangerously-skip-permissions` under herdr. RESOLVED, with one carve-out that cost a live failure.** The flag rides the same `--` passthrough as O1, opt-in via `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS`. With it off, herdr *does* report a permission gate honestly as `blocked`, and both halves act on that: delivery refuses (a work order submitted into a gate answers the gate instead of starting a turn), and the response wait reports it as "a human must look" rather than a timeout. The carve-out: **the startup trust dialog is not reported as `blocked`** (see O2) — herdr says `interactive_ready:true, idle` — and `HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS` does not cover it either, because directory trust is not a permission mode. That gate needs the screen probe; `blocked` alone would have missed the exact case its refusal names.
- **O7 — model / tools passthrough. RESOLVED.** Both ride O1's verified `--` passthrough: `HOTLINE_CLAUDE_MODEL` → `--model`, and the allowed-tools list → `--allowedTools=<list>` kept in its `=`-joined one-word form (some recorders treat `--allowedTools` as arity-0 and drop a space-separated value, resurrecting the callee later with an empty list). One flag is deliberately *not* passed: `-n <session-name>`, whose herdr passthrough is unverified — the herdr agent name carries the call's identity in `agent list` instead.
- **O8 — payload privacy. RESOLVED: yes it does, and the exposure is accepted for Phase 1.** `herdr agent prompt <target> <text>` takes its text positionally and herdr 0.8.0 offers no file or stdin form (`herdr api` is read-only metadata), so the work order is on argv — readable by any local user through `ps` — for the lifetime of one short-lived process. Everything upstream of that hop stays on a file (`--payload-file`), which narrows the window cmux eliminated from "the whole callee session" to sub-second. Documented rather than hidden; revisit if herdr grows a file-based prompt form.

### 9.2 Open questions (verify before/while building)

Both gate Phase 3, and neither has shipped code to cite yet.

- **O5 — remote transcript access.** For `--remote`, where does the callee transcript live and how do we read it locally (§7)? Phase 1 shipped local-detached only and `dial.sh` refuses `--remote` on this question's account (§4 step 3), so it now gates Phase 3's remote support outright.
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

---

## 12. Deviations (as shipped)

Four places where the shipped code reads differently from the sections above.

**Transport scripts are flat, not nested (§10, Phase 0).** As of Phase 1
(PR #20), `skills/dial/scripts/` holds `cmux-*`, `herdr-*` and `headless-*` side
by side; there is no `transports/<backend>/` subtree. The prefix carries the
grouping a directory would, and it keeps every backend's scripts one segment
deep under `${CLAUDE_SKILL_DIR}/scripts/` — the path each `SKILL.md` block,
`allowed-tools` matcher and sibling script resolves through.

**A transport this hotline has no verbs for is refused, not degraded (§2.1, §4
step 2).** A `transport.txt` naming a backend outside `HOTLINE_TRANSPORTS`
(`cmux herdr headless`) exits both waiters non-zero, naming the value it could
not read and the set it knows; the judgement lives once, in
`scripts/transport.sh`. §4 step 2's "never silently to cmux" governs the read
side as much as the selection side, and headless is no better a target than cmux
here — file-watching a `done` nobody will write turns a one-word mismatch into up
to 30 minutes of silence before `--timeout` expires, where cmux at least fails
against a host of the wrong kind. Saying so beats both.

An ABSENT or EMPTY `transport.txt` is a separate case and keeps §2.1's behavior:
it names nothing, so the waiters infer the backend from the host handles as
before. That is what preserves the handle-less-cmux carve-out — `transport.txt`
is written with the call dir, well before a host is placed, so a launcher that
dies in between hands the waiter a dir whose own `error.txt` only the file-watch
path reports.

**An explicit `--transport herdr` whose preflight fails is an error, not a
degrade (§4 step 2, §11 constraint 2).** `dial.sh` step 3 emits a `transport`
error carrying `check-herdr.sh`'s own reason and recovery; no `.fallbacks` entry
is written, because nothing was fallen back to. Headless is the wrong degrade
target for this particular ask: it has no live host to follow up into at all, so
it answers a request for a callee that survives disconnect with one that cannot
be re-addressed even while it runs. The universal headless fallback is
untouched — it remains the degrade target of the cmux chain, which is every dial
that names no transport.

**`HOTLINE_TRANSPORT=herdr` env selection is not shipped (§4 step 4).** The
shipped precedence is three steps: `--headless`/`HOTLINE_FORCE_HEADLESS` →
headless, explicit `--transport herdr` → herdr or error, otherwise cmux with its
existing degrade chain. Nothing reads a `HOTLINE_TRANSPORT` variable, and §10
placed step 4 in Phase 1, so it is dropped rather than deferred to a later
phase. `--transport herdr` reaches every case the step was for, and it does so at
the call rather than from the ambient environment — the same reason §4 gives for
refusing to let `HERDR_ENV=1` select a transport applies to a variable one
settings file further away. A caller who wants a standing herdr default puts it
in a wrapper around `dial.sh`, where it is visible to whoever reads the call.
