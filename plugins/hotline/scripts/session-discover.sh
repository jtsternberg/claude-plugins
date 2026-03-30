#!/usr/bin/env bash
# session-discover.sh
#
# Finds the Claude Code session ID by grepping transcript files for a planted fingerprint.
#
# Usage: session-discover.sh <fingerprint>
#
#   <fingerprint> - The SESSION_FINGERPRINT_<uuid> string output by session-fingerprint.sh
#
# The fingerprint must have been emitted into the conversation transcript before calling
# this script. The transcript filename (minus .jsonl) IS the session ID.
#
# On success: writes session ID to stdout, exit 0
# On failure: writes error to stderr, exit 1
#
# Also caches the result to /tmp/claude-session-<claude-pid> so subsequent
# session-fingerprint.sh calls return immediately (cache hit, exit 0).

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: session-discover.sh <fingerprint>"
  echo ""
  echo "Finds the Claude Code session ID by grepping transcripts for a planted fingerprint."
  echo "On success: writes session ID to stdout, exit 0. On failure: exit 1."
  exit 0
fi

FINGERPRINT="${1:-}"

if [[ -z "$FINGERPRINT" ]]; then
  echo "Usage: session-discover.sh <fingerprint>" >&2
  exit 1
fi

PROJECT_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: No transcript directory found at $PROJECT_DIR" >&2
  exit 1
fi

TRANSCRIPT=""
for f in $(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -5); do
  if grep -q "$FINGERPRINT" "$f"; then
    TRANSCRIPT="$f"
    break
  fi
done

if [[ -z "$TRANSCRIPT" ]]; then
  echo "Error: Fingerprint not found in recent transcripts" >&2
  exit 1
fi

SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)

# Cache for future session-fingerprint.sh calls
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

if [[ -n "$CLAUDE_PID" ]]; then
  echo "$SESSION_ID" > "/tmp/claude-session-${CLAUDE_PID}"
fi

echo "$SESSION_ID"
