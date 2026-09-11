#!/usr/bin/env bash
# =============================================================================
# Call Status: print the hotline call registry as JSON lines, one per callee.
#
# Read-only. It runs the shared registry reader at <plugin>/scripts/call-registry.mjs
# — the same one the switchboard server uses — and touches nothing else: no
# registry writes, no switchboard process or browser, no transcripts.
#
# Usage:
#   call-status.sh [sessions-dir]
#
# Defaults to $HOTLINE_SESSIONS_DIR, else ~/.agents-hotline/sessions. An empty or
# missing registry prints nothing and exits 0. A malformed registry file is
# skipped with a stderr warning; every other entry still comes through.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: call-status.sh [sessions-dir]"
  echo ""
  echo "Prints one JSON object per hotline callee: caller_session_id, caller_path,"
  echo "target, callee_session_id, mode, started, last_contact, exchange_count,"
  echo "host_handle, transport, remote."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/../../../scripts/call-registry.mjs"

if ! command -v node >/dev/null 2>&1; then
  echo "call-status: node not found on PATH — install Node.js to read the call registry" >&2
  exit 1
fi

if [[ ! -f "$READER" ]]; then
  echo "call-status: shared registry reader not found at $READER" >&2
  exit 1
fi

exec node "$READER" ${1+"$1"}
