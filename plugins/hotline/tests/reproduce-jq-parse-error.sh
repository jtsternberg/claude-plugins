#!/usr/bin/env bash
# =============================================================================
# Reproduce the jq parse-error observed when callers run the SKILL.md caller
# pattern under zsh. See tests/fixtures/jq-parse-error-zsh-echo/NOTES.md.
#
# On a pre-fix checkout this script exits 1 (bug reproduces).
# On a post-fix checkout it exits 0 (caller pattern survives zsh).
#
# Usage: bash plugins/hotline/tests/reproduce-jq-parse-error.sh
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/jq-parse-error-zsh-echo"
DIAL_SCRIPTS="$SCRIPT_DIR/../skills/dial/scripts"

# Stage a call_dir that mimics a completed headless call
CALL_DIR=$(mktemp -d "/tmp/hotline-repro-XXXXX")
cp "$FIXTURE_DIR/stream.jsonl" "$CALL_DIR/stream.jsonl"
cp "$FIXTURE_DIR/response.json" "$CALL_DIR/response.json"
touch "$CALL_DIR/done"

# The SKILL.md caller pattern, executed under zsh — which is how it runs in
# practice for agents whose login shell is zsh.
if ! command -v zsh >/dev/null 2>&1; then
  echo "zsh not found; skipping reproduction" >&2
  rm -rf "$CALL_DIR"
  exit 77
fi

OUTPUT=$(zsh -c '
  RESPONSE_JSON=$(bash "'"$DIAL_SCRIPTS"'/wait-for-response.sh" "'"$CALL_DIR"'")
  echo "$RESPONSE_JSON" | jq -r ".response"
' 2>&1) || STATUS=$?
STATUS=${STATUS:-0}

rm -rf "$CALL_DIR"

if echo "$OUTPUT" | grep -q "parse error"; then
  echo "REPRODUCED: caller pattern fails under zsh"
  echo "---"
  echo "$OUTPUT" | head -3
  exit 1
fi

if [[ $STATUS -ne 0 ]]; then
  echo "UNEXPECTED: caller pattern exited $STATUS without parse error" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

echo "OK: caller pattern survives zsh (bug no longer reproduces)"
exit 0
