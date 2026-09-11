#!/usr/bin/env bash
# =============================================================================
# Call Status: print the hotline call registry as JSON lines, one per callee.
#
# Read-only. It runs the shared registry reader at <plugin>/scripts/call-registry.mjs
# — the same one the switchboard server uses — and touches nothing else: no
# registry writes, no switchboard process or browser, no transcripts.
#
# Usage:
#   call-status.sh [--plugin-root <dir>] [sessions-dir]
#
# --plugin-root is how the skill hands over the installed plugin directory, so
# the reader is addressed from the plugin root rather than by counting parent
# directories. Omit the flag entirely and the script falls back to its own
# location, which keeps a direct invocation (and the tests) working; pass it with
# no value and it exits 2, because a --plugin-root that resolves to nothing is a
# broken invocation, not a request for the fallback.
#
# Defaults to $HOTLINE_SESSIONS_DIR, else ~/.agents-hotline/sessions. An empty or
# missing registry prints nothing and exits 0. A malformed registry file is
# skipped with a stderr warning; every other entry still comes through.
# =============================================================================
set -uo pipefail

PLUGIN_ROOT=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      echo "Usage: call-status.sh [--plugin-root <dir>] [sessions-dir]"
      echo ""
      echo "Prints one JSON object per hotline callee: caller_session_id, caller_path,"
      echo "target, callee_session_id, mode, started, last_contact, exchange_count,"
      echo "host_handle, transport, remote."
      exit 0
      ;;
    --plugin-root|--plugin-root=*)
      if [[ "$1" == --plugin-root ]]; then
        PLUGIN_ROOT="${2-}"
        [[ $# -ge 2 ]] && shift 2 || shift
      else
        PLUGIN_ROOT="${1#*=}"
        shift
      fi
      if [[ -z "$PLUGIN_ROOT" ]]; then
        echo "call-status: --plugin-root needs a directory (omit the flag to use the script's own location)" >&2
        exit 2
      fi
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$PLUGIN_ROOT" ]]; then
  READER="$PLUGIN_ROOT/scripts/call-registry.mjs"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  READER="$SCRIPT_DIR/../../../scripts/call-registry.mjs"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "call-status: node not found on PATH — install Node.js to read the call registry" >&2
  exit 1
fi

if [[ ! -f "$READER" ]]; then
  echo "call-status: shared registry reader not found at $READER" >&2
  exit 1
fi

exec node "$READER" ${ARGS[@]+"${ARGS[@]}"}
