#!/usr/bin/env bash
# Print a harness-specific handoff command.

set -euo pipefail

action='pickup-handoff'
explicit_action=0
if [ "${1:-}" = '--action' ]; then
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
    printf 'Usage: %s [--action handoff [argument]|pickup-handoff <handoff-identifier>]\n' "${0##*/}" >&2
    exit 2
  }
  action=$2
  explicit_action=1
  shift 2
fi

case "$action" in
  handoff)
    [ "$#" -le 1 ] || {
      printf 'Usage: %s --action handoff [argument]\n' "${0##*/}" >&2
      exit 2
    }
    ;;
  pickup-handoff)
    if [ "$#" -eq 0 ] && [ "$explicit_action" -eq 1 ]; then
      : # Render the command base; callers can append display-only prose.
    elif [ "$#" -ne 1 ] || [ -z "$1" ]; then
      printf 'Usage: %s [--action pickup-handoff] <handoff-identifier>\n' "${0##*/}" >&2
      exit 2
    fi
    ;;
  *)
    printf 'Unsupported handoff action: %s\n' "$action" >&2
    exit 2
    ;;
esac

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  command_name="/handoff:${action}"
elif [ -n "${CODEX_THREAD_ID:-}" ]; then
  command_name="\$handoff:${action}"
else
  printf 'Cannot determine harness: CLAUDE_CODE_SESSION_ID and CODEX_THREAD_ID are both unset.\n' >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  printf '%s\n' "$command_name"
else
  printf '%s %q\n' "$command_name" "$1"
fi
