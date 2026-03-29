#!/usr/bin/env bash
# session-fingerprint.sh
#
# Discovers the agent's own Claude Code session ID via a fingerprint method.
#
# Usage: session-fingerprint.sh
#
# Exit codes:
#   0 - Cache hit: session ID written to stdout
#   1 - Cache miss: unique fingerprint string written to stderr (SESSION_FINGERPRINT_<uuid>)
#       The caller must plant this string in the transcript, then run session-discover.sh
#   2 - Error: no claude process found in process ancestry
#
# Convention: the fingerprint on stderr signals the caller to grep transcripts.
# Once found, session-discover.sh caches the result so future calls are instant.

set -euo pipefail

# Find the claude process in our ancestry
CLAUDE_PID=""
pid=$$
while [[ "$pid" != "1" && -n "$pid" ]]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs)
  if [[ "$comm" == "claude" ]]; then
    CLAUDE_PID="$pid"
    break
  fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

if [[ -z "$CLAUDE_PID" ]]; then
  echo "Error: Could not find claude process in ancestry" >&2
  exit 2
fi

CACHE_FILE="/tmp/claude-session-${CLAUDE_PID}"

# Cache hit — return session ID on stdout, exit 0
if [[ -f "$CACHE_FILE" ]]; then
  cat "$CACHE_FILE"
  exit 0
fi

# Cache miss — plant fingerprint on stderr, exit 1
FINGERPRINT="SESSION_FINGERPRINT_$(uuidgen)"
echo "$FINGERPRINT" >&2
exit 1
