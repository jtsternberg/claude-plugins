# Fixture: jq parse error via zsh `echo`

Captured 2026-04-21. Tracks claude-plugins-82u / claude-plugins-2io.

## What this fixture represents

`stream.jsonl` is a synthetic `claude -p --output-format stream-json` stream that
contains a `result` event whose `.result` string has:

- Real newlines (`\n`)
- A form-feed control byte (`\u000c`)
- ANSI escape sequences (`\u001b[31m ... \u001b[0m`)

`response.json` is what `headless-call-async.sh` produces on disk for that stream.
It is **valid JSON** — you can verify with `jq -e . response.json` (exit 0).

## How the bug reproduces

The caller pattern documented in `plugins/hotline/skills/dial/SKILL.md`:

```bash
RESPONSE_JSON=$(bash wait-for-response.sh "$CALL_DIR")
echo "$RESPONSE_JSON" | jq -r '.response'
```

Works under bash. Fails under zsh with:

    parse error: Invalid string: control characters from U+0000 through U+001F
    must be escaped at line N, column M

## Root cause

Claude Code's Bash tool runs commands in the user's login shell. On macOS that
is typically zsh. **zsh's built-in `echo` interprets backslash escape sequences
by default** — `\f` becomes 0x0c, `\n` becomes a real newline, `\u001b` becomes
0x1b, etc.

When the valid JSON `{"response":"...\f..."}` is captured into a shell variable
and then piped through `echo "$VAR"`, zsh rewrites the escape sequences into
actual control bytes before jq sees the stream. The resulting bytes are no
longer valid JSON (JSON forbids unescaped U+0000..U+001F inside strings), so
jq rejects them with the observed parse error.

## Verification

jq version on the affected system: `jq-1.6` (Homebrew on Darwin). No jq bug —
jq is correctly escaping output, and correctly rejecting malformed input. The
corruption happens entirely inside zsh's `echo` between the two jq invocations.

## Reproduction script

See `plugins/hotline/tests/reproduce-jq-parse-error.sh`. It deliberately keeps
the unsafe zsh `echo` pattern as a reproduction case, so it is expected to
continue exiting 1 with the parse error on every checkout — the fix landed in
PR #1 swaps the *documented* caller pattern (SKILL.md), not the unsafe pattern
itself. The repro only stops failing if the emitter output ever changes in a
way that removes backslash escapes; at that point SKILL.md needs a re-audit.
