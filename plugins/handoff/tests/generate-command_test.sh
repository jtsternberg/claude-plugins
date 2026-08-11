#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/skills/handoff/scripts/generate-command.sh"
[ -f "$SCRIPT" ] || { echo "cannot find generator at $SCRIPT" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

run_clean() {
  env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID "$@"
}

out=$(run_clean env CLAUDE_CODE_SESSION_ID=claude-session bash "$SCRIPT" proj-123)
if [ "$out" = '/handoff:pickup-handoff proj-123' ]; then
  pass "Claude emits slash-command invocation"
else
  fail "Claude invocation was: $out"
fi

out=$(run_clean env CODEX_THREAD_ID=codex-thread bash "$SCRIPT" proj-123)
if [ "$out" = "\$handoff:pickup-handoff proj-123" ]; then
  pass "Codex emits dollar-command invocation"
else
  fail "Codex invocation was: $out"
fi

out=$(run_clean env CLAUDE_CODE_SESSION_ID=claude-session CODEX_THREAD_ID=codex-thread \
  bash "$SCRIPT" proj-123)
if [ "$out" = '/handoff:pickup-handoff proj-123' ]; then
  pass "Claude marker takes precedence when both are present"
else
  fail "dual-marker invocation was: $out"
fi

out=$(run_clean env CODEX_THREAD_ID=codex-thread bash "$SCRIPT" '/tmp/My Work/HANDOFF.md')
if [ "$out" = "\$handoff:pickup-handoff /tmp/My\\ Work/HANDOFF.md" ]; then
  pass "identifier is escaped for pasting into a shell"
else
  fail "escaped invocation was: $out"
fi

out=$(run_clean env CODEX_THREAD_ID=codex-thread bash "$SCRIPT" --action handoff)
if [ "$out" = "\$handoff:handoff" ]; then
	pass "Codex emits a no-argument handoff command"
else
	fail "Codex handoff invocation was: $out"
fi

if run_clean bash "$SCRIPT" proj-123 >/dev/null 2>&1; then
  fail "missing harness marker must fail"
else
  pass "missing harness marker fails"
fi

if run_clean env CODEX_THREAD_ID=codex-thread bash "$SCRIPT" >/dev/null 2>&1; then
  fail "missing identifier must fail"
else
  pass "missing identifier fails"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
