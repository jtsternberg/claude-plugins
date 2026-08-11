# hotline: `dial.sh` orchestrator wrapper

Collapse the dial skill's model-issued plumbing (paths eval → identity → resolve → cmux check
→ cache check → fire → wait-for-boot) into one wrapper script with a single JSON contract.
SKILL.md shrinks from a decision tree of ~8 Bash blocks to one command plus a status table.

## Why this works

Every script in the chain (`resolve-workspace.sh`, `check-cmux.sh`, `session-cache.sh`,
`cmux-call-async.sh`, `wait-for-session.sh`) is plain synchronous bash with clean
argv/stdout/exit-code contracts. The plugin already trends this way — `session-init.sh`,
`register-call.sh`, and `persist-call-meta.sh` all exist because model-discipline steps kept
getting skipped. Nothing composes the top-level flow yet; that's the gap.

## Identity: one call now, two only for legacy clients

Claude Code >= 2.1.132 exports `CLAUDE_CODE_SESSION_ID` into every Bash subprocess, and it
equals the resumable session/transcript ID. `session-init.sh` resolves identity in a single
invocation with precedence `HOTLINE_CALLER_SESSION_ID` → `CLAUDE_CODE_SESSION_ID` (caller kind
`native`) → `CODEX_THREAD_ID` → the legacy fingerprint discovery. So on any current client the
wrapper completes the whole flow in one tool call.

The fingerprint fallback is the only path that can't finish in one invocation: plant → discover
**cannot** happen inside a single script run, because the fingerprint lands in the transcript
only after the tool call *returns* — a script can't grep for output the harness hasn't flushed
yet. That path stays reachable for pre-2.1.132 clients (and for a stripped or malformed env
var), so the wrapper is **re-entrant**:

1. Wrapper calls `session-init.sh`. Identity resolved (the normal case) → proceed, everything in
   one call.
2. Unresolved → plant the fingerprint to stderr as today, persist it as pending state keyed by
   the claude PID (`/tmp/hotline-pending-<pid>`), emit `{"status":"replay","hint":"run this exact
   command again"}`, exit 2.
3. The model re-runs **the same command verbatim**. The wrapper finds the pending fingerprint,
   discovers the session ID, caches it to `/tmp/claude-session-<pid>`, and continues into the
   full flow.

No fingerprint plumbing in SKILL.md at all — the only prose rule is "if `status` is `replay`,
run the identical command a second time," and current clients never hit it. Steady state is one
invocation.

## Interface

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/dial/scripts/dial.sh" \
  --target "<user's workspace reference>" \
  --mode work_order \                 # quick|work_order|conference
  --prompt-file /tmp/hotline-prompt.txt \
  [--placement side|window|detached] [--headless] \
  [--resume <session-id> [--no-fork]] [--caller-session <id>]
```

`--prompt-file` instead of an inline arg kills the quoting/escaping hazards the current
SKILL.md warns about. The wrapper writes the `[MODE:]/[CALLER:]/[SESSION:]` tags and the
`/hotline:hotline-ringing` wrapping itself (first contact) or sends raw (follow-up).

## Internal flow

1. **Identity** — as above; one `session-init.sh` call, `replay`/exit 2 only on the legacy path.
2. **Resolve workspace** — `resolve-workspace.sh`. Ambiguous → `{"status":"needs_disambiguation",
   "candidates":[...]}` and stop (model asks the user, re-runs with the picked path). Stale
   identity → run the `is-stale` + headless pickup-refresh + retry loop *internally*; it's
   mechanical, the model adds nothing.
3. **Transport** — `check-cmux.sh`; a `{"fallback":"headless"}` from the cmux launcher is
   re-fired through the headless launcher *internally* and recorded in a `fallbacks` array
   instead of bouncing back to the model.
4. **Session cache** — `session-cache.sh get`. Existing session + `surface_ref` + single-line
   message → `cmux-reuse-surface.sh`; its `{"fallback":"fresh"}` → resume-fresh path. No
   cached session → first contact.
5. **Fire** — `cmux-call-async.sh` / `headless-call-async.sh` per mode+transport.
   Conference mode: `cmux-call.sh`, early-return after it (it self-registers; no wait loop —
   preserves today's behavior).
6. **Wait for boot** — `wait-for-session.sh` (registration already happens inside it).
7. **Emit payload** and exit.

## Output contract

One JSON object, success or failure:

```json
{
  "status": "connected",            // connected | needs_disambiguation | error | replay (legacy only)
  "caller_session_id": "53ed…",
  "workspace": "/Users/JT/Code/claude-plugins",
  "mode": "work_order",
  "transport": "cmux",              // cmux | headless
  "placement": "side",
  "first_contact": true,
  "remote_session_id": "4e48…",
  "call_dir": "/tmp/hotline-call-FUpqY",
  "surface_ref": "…",
  "fallbacks": []                   // e.g. ["cmux-cli-missing→headless", "surface-context→detached"]
}
```

Errors: `{"status":"error","stage":"resolve|transport|fire|boot","detail":"<actual stderr>",
"recovery":"<one-line hint from error-recovery.md>"}`. Prose error-handling in SKILL.md
reduces to "surface `detail` and `recovery` to the user; never silently retry."

## What deliberately stays out of the wrapper

- **`wait-for-response.sh`** — it's long-running (work orders can exceed Bash tool timeouts),
  and the model must report the connection to the user *between* boot and response. Stays a
  separate step, unchanged, including exit 3 (reassigned) / exit 4 (AWAITING_REVIEW) semantics.
- **Judgment calls** — mode inference (quick vs work order vs conference), sanity-checking the
  resolved workspace against the user's words, disambiguation asks, fork-vs-assist intent when
  the user hands a session ID. That's what the prose is *for*; it stays.

## What dies

- The `eval "$(paths.sh)"` boilerplate in SKILL.md — the wrapper self-locates via `BASH_SOURCE`
  like every other script already does. (Keep `paths.sh` itself; other skills reference it.)
- The Step 3/4/5 decision-tree prose — replaced by the status table.
- The zsh/jq escape warning — moot with `--prompt-file` and file-based output.

## Risk & testing

Low: the wrapper *composes* existing tested scripts, changes none of them. Add
`tests/dial_wrapper_test.sh` with the stubbed-`cmux` pattern the existing suites use, covering:
native/cached-identity happy path (single call), legacy replay round-trip with
`CLAUDE_CODE_SESSION_ID` unset, disambiguation exit, headless fallback fold-in,
follow-up reuse vs resume-fresh, conference early-return.

Dual-harness: one command is *easier* for Codex (one path substitution instead of eight);
identity already handles Codex via `CODEX_THREAD_ID` in `session-init.sh`. Run
`validate-dual-harness-skill` on the edited SKILL.md.

## Separate observation (not this change)

The `block-external-uploads.sh: No such file or directory` spam in the transcript is the
*caller workspace's* PreToolUse hook (lindris-monorepo settings pointing at a deleted script)
— unrelated to hotline, fix it there.
