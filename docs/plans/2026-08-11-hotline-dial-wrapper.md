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

## The one hard constraint: identity

Fingerprint plant → discover **cannot** happen inside a single script invocation. The
fingerprint lands in the transcript only after the tool call *returns* — a script can't grep
for output the harness hasn't flushed yet. So worst case is two tool calls, period.

But it doesn't have to stay a distinct model-managed step. Make the wrapper **re-entrant**:

1. Wrapper checks `HOTLINE_CALLER_SESSION_ID` / `--caller-session` / the `/tmp/claude-session-<pid>`
   cache. Hit (the common case) → proceed, everything in one call.
2. Miss → plant the fingerprint to stderr as today, persist it as pending state keyed by the
   claude PID (`/tmp/hotline-pending-<pid>`), emit `{"status":"replay","hint":"run this exact
   command again"}`, exit 2.
3. The model re-runs **the same command verbatim**. The wrapper finds the pending fingerprint,
   discovers the session ID, caches it, and continues into the full flow.

No fingerprint plumbing in SKILL.md at all — the only prose rule is "if `status` is `replay`,
run the identical command a second time." Steady state is one invocation.

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

1. **Identity** — as above.
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
  "status": "connected",            // replay | needs_disambiguation | connected | error
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
cached-identity happy path, replay round-trip, disambiguation exit, headless fallback fold-in,
follow-up reuse vs resume-fresh, conference early-return.

Dual-harness: one command is *easier* for Codex (one path substitution instead of eight);
identity already handles Codex via `CODEX_THREAD_ID` in `session-init.sh`. Run
`validate-dual-harness-skill` on the edited SKILL.md.

## Separate observation (not this change)

The `block-external-uploads.sh: No such file or directory` spam in the transcript is the
*caller workspace's* PreToolUse hook (lindris-monorepo settings pointing at a deleted script)
— unrelated to hotline, fix it there.
