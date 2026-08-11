#!/usr/bin/env bash
# Print the harness-specific command for resuming one concrete handoff.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'Usage: %s <handoff-identifier>\n' "${0##*/}" >&2
  exit 2
fi

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  command_name='/handoff:pickup-handoff'
elif [ -n "${CODEX_THREAD_ID:-}" ]; then
  command_name="\$handoff:pickup-handoff"
else
  printf 'Cannot determine harness: CLAUDE_CODE_SESSION_ID and CODEX_THREAD_ID are both unset.\n' >&2
  exit 1
fi

printf '%s %q\n' "$command_name" "$1"
