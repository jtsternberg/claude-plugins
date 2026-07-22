# Hotline cmux transport: transcript-tail instead of screen-scraping

**Status:** design accepted, not yet implemented
**bd:** claude-plugins-0pwc (transport rework) · claude-plugins-5zhp (send/submit bug — fixed, shipped in the two-step `send` + `send-key Enter` change)
**Date:** 2026-07-22

## Problem

The cmux-surface transport confirms submits and captures responses by scraping
the rendered terminal (`cmux read-screen`), regex-hunting `STATUS: <sig>
call_id=<nonce>` lines and stripping chrome (`grep -vE "^[╭│╰─└┌┘┐ℹ]"`, prompt
glyphs, ANSI). This is coupled to undocumented, version-specific claude REPL
rendering. Live proof it rots: a detector written against a `│`-bordered input
box was silently wrong — claude v2.1.216 renders the prompt as `❯ …` between
`───` rules, no `│`. JT's framing: "you are parsing for strings off a screen —
that seems real fragile."

## Decision

Read the callee's **Claude Code conversation JSONL transcript** — the structured
source of truth — instead of the rendered screen. Keep the current read-screen
loop only as an explicit fallback tier while confidence builds.

### Why (verified, not assumed)

- Claude Code **flushes each event to the transcript JSONL in real time** — a
  live session's file was 6s stale mid-turn, ms-timestamped per event. Polling
  the tail gives near-instant submit + response detection. (This was the
  make-or-break question; it passed.)
- `type:"user"` events carry `.message.content` with the exact typed text,
  including the `[CALL_ID: <nonce>]` prefix → **determinate submit signal**,
  and it *separates* the two failure modes the screen-scrape conflated:
  - no user event with the nonce → **never submitted** → fail fast (~10-15s).
  - user event present, no assistant end_turn yet → **submitted, model slow** →
    patient timeout (the old 1800s ceiling is fine here).
- `type:"assistant"` events carry `.message.content[]` text blocks plus
  `.message.stop_reason` (`"end_turn"` = turn complete vs `"tool_use"` = more
  coming). Response = concatenated assistant text blocks up to `end_turn`. There
  is also a `type:"system"` `subtype:"turn_duration"` event at turn end.
- **hotline already computes the path.** `wait-for-session.sh` derives
  `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` (encoding: each
  non-alphanumeric → `-`) and uses file existence as a boot check. Session id is
  known on every cmux path (preset via `--session-id` on fresh calls; passed via
  `--session` on reuse). cwd is persisted. ~80% of the plumbing exists.
- **Visible-surface UX preserved for free** — nothing about what the callee
  prints changes; we read truth from a different place.
- **Remote-neutral** — the remote design (docs/plans/2026-07-08-remote-call-design.md)
  runs headless `claude -p` on the callee's machine; structured capture is local
  there, caller never reads a remote disk. call_dir/response.json contract holds.

### Rejected alternatives

- **Callee writes response.json via its own Bash tool** — makes the *transport*
  depend on model compliance, and hits permission gates on non-`--dangerously-skip`
  callees (esp. the reuse path into a user's own session) — the exact stall class
  we're escaping. Fine as an optional progress channel for long work orders; wrong
  as the backbone.
- **Claude Code hooks injected at launch (Stop hook → call_dir)** — can't be
  injected into the reuse path (session already running), and the Stop hook would
  read the transcript JSONL anyway. It's this design with extra moving parts.
  Possible later hardening.
- **cmux events / agent-session surfaces** — cmux's Claude hook integration only
  fires when claude is launched through cmux's own wrapper (hotline doesn't), and
  events don't carry response bodies. Couples us to cmux internals in a
  remote-hostile way. Maybe useful later as a wake-up signal to replace `sleep 2`.

## Migration sketch (design only)

1. **New shared helper** (e.g. `scripts/transcript-path.sh`): factor the
   cwd+session-id → JSONL path logic out of `wait-for-session.sh:114-118`.
2. **`cmux-call-async.sh` / `cmux-reuse-surface.sh`**: write `transcript_path.txt`
   into the call_dir. Reuse path needs cwd (from the sessions registry or a new
   `--cwd` arg).
3. **`wait-for-session.sh`**: promote transcript-file existence to the primary
   boot signal; demote banner regex to fallback.
4. **`wait-for-response.sh`** (the heart): when `transcript_path.txt` exists and
   is readable, poll the JSONL instead of `read-screen`:
   - `jq`-scan for the `user` event containing the nonce → submit confirmed
     (new, short `--submit-deadline`, distinct error for 0pwc).
   - collect subsequent `assistant` text blocks; on `stop_reason:"end_turn"`
     (or `turn_duration`), assemble response, apply existing STATUS semantics
     (last-WIP-resets-buffer, terminal-STATUS classification) against
     **structured text**, strip STATUS lines, write `response.json` + `done`.
     Same stdout contract — dial SKILL.md flow unchanged.
   - transcript absent / never appears while screen shows life → fall back to the
     current read-screen loop (keep intact as one function). Mode detection stays
     additive file-sniffing; old call_dirs/launchers keep working.
5. **`ringing/SKILL.md`**: protocol unchanged — STATUS + nonce still required
   (semantic layer + fallback anchor). Optionally reframe the "body-start marker
   for terminal chrome" rationale as "correlation marker."
6. **Tests** (`tests/wait-for-response_test.sh`): synthetic JSONL fixtures —
   user-with-nonce, tool_use chain, end_turn, multi-text-block turns, replayed
   `--resume` transcripts carrying old nonces.
7. **bd**: this design closes the *approach* question for 0pwc; file the
   implementation task; note fallback-tier removal as later cleanup once
   live-proven.

## Risks / open questions needing a live test

1. **Queued input**: if the callee is mid-turn when we `cmux send`, claude queues
   it (`queue-operation` events exist). Does the `user` event appear at enqueue or
   dequeue? Submit-deadline may need to also accept a queue-operation with the nonce.
2. **`--resume` / `--fork-session` shape**: resume appends to the same id
   (expected); fork writes a new id we must discover (session-discover/newest-file
   heuristic should cover — verify).
3. **Multi-message turns**: confirm one visual "response" can span several
   `assistant` events before `end_turn`; concatenating text blocks reproduces the
   screen. Filter subagent/sidechain events (`isSidechain`?).
4. **Permission-blocked callee**: stalls with no `end_turn`; timeout still catches
   it, but a nicer "awaiting permission" diagnostic may be readable from the last
   event.
5. **File readability**: transcripts are `0600` same-user — fine same-machine;
   confirm cmux never runs the callee as a different user (it doesn't today).
6. **Schema stability**: internal, but far more stable than TUI pixels, and the
   headless `stream-json` path already bets on adjacent internals. The retained
   scrape fallback is the insurance.
