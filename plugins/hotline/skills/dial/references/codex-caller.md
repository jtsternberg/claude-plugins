# Hotline From Codex (non-Claude callers)

Hotline's caller-identity discovery was built for Claude Code, which has no clean
self-ID API — so it plants a fingerprint in the transcript and greps
`~/.claude/projects/**/<id>.jsonl` to recover the session ID. A Codex session has
no `claude` process in its ancestry, so that machinery can't run. This file covers
how a **Codex-run** agent (or any non-Claude caller) gets a stable identity so the
rest of the dial flow works unchanged.

You only need this file if you're running under Codex (or another non-Claude
harness). Claude callers: ignore it — the main `SKILL.md` flow is for you.

## The short version

`session-init.sh` already handles Codex. When it can't find a `claude` process it
checks `$CODEX_THREAD_ID` and, if set, returns:

```json
{ "status": "cached", "session_id": "<CODEX_THREAD_ID>", "caller_kind": "codex" }
```

Store `session_id` as `MY_SESSION_ID` and continue the dial flow normally. There's
nothing extra to do — the ID flows through `session-cache.sh` (as a filename key)
and into the `[SESSION:]` ringing tag exactly like a Claude session ID would.

## Why `$CODEX_THREAD_ID` is the right source

Verified against codex-cli 0.142.5:

- **It's always set.** Every shell Codex spawns gets `$CODEX_THREAD_ID`, and it *is*
  the current session/thread ID. No fingerprint, no transcript grep.
- **It's stable across resume.** `codex exec resume <id>` re-enters the same thread
  and the shell sees the same value — so an outgoing-call cache keyed by this ID
  survives a resume.
- **It's present in every launch mode** tested: interactive TUI, `codex exec`,
  `codex exec resume`, piped prompt (`… | codex exec -`), `--ephemeral`, and
  `--ignore-user-config`. No mode was found where a running Codex shell lacks it.
- **It's filesystem-safe.** The value is a plain lowercase hyphenated UUIDv7
  (e.g. `019f3e22-8115-7c43-b49a-3b3f955d9d46`) — no colon, safe as a cache-filename
  segment as-is. No prefixing needed; `caller_kind: "codex"` carries the "kind"
  separately in the JSON.

## Escape hatch: `HOTLINE_CALLER_SESSION_ID`

For tests, non-Codex non-Claude tools, or debugging, set an explicit ID in the
environment:

```bash
HOTLINE_CALLER_SESSION_ID=<stable-id> bash "$HOTLINE_SCRIPTS/session-init.sh"
# → {"status":"cached","session_id":"<stable-id>","caller_kind":"override"}
```

This takes precedence over everything — the override short-circuits before the
fingerprint/Codex logic runs.

## Fallback (defensive only — not a normal path)

If `$CODEX_THREAD_ID` is somehow absent (an old Codex, a stripped shell env, a
nonstandard wrapper), Codex persists a transcript you can recover the ID from:

```text
~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl
```

The first JSONL record has `type: "session_meta"` with `payload.session_id` and
`payload.id` both equal to the session ID; the filename also embeds it. This is a
last resort — **don't build the normal flow around it.** Note `codex exec
--ephemeral` sets `$CODEX_THREAD_ID` but writes **no** transcript, so the scan can't
help there anyway; the env var is the only source in ephemeral mode.

## Caveat: caller-side resume / takeover differs

The `[SESSION:]` tag you hand the receiver is your caller ID, used if the receiver
ever needs to reach back. Hotline's launch scripts resume sessions with
`claude --resume`, which **cannot** resume a Codex thread — so a Claude receiver
calling *back* into your Codex session isn't wired up. What works:

- **Outbound dialing from Codex** → fully supported (this is the common case).
- **Receiver-side sessions** (the Claude workspace you dialed) → work normally;
  you can resume *them* from your side.
- **Reaching back into a Codex caller** → not supported yet; it would need a
  `codex resume`-based transport. If you need the human to take over a Codex-side
  session, hand them `codex resume <MY_SESSION_ID>` directly rather than
  `claude --resume`.
