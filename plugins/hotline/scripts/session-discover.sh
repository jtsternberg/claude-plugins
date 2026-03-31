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

PROJECTS_ROOT="$HOME/.claude/projects"

if [[ ! -d "$PROJECTS_ROOT" ]]; then
  echo "Error: No projects directory found at $PROJECTS_ROOT" >&2
  exit 1
fi

# Retry up to 3 times with 1s delay — Claude Code writes transcripts
# asynchronously, so the fingerprint may not be flushed to disk yet
# by the time this runs in the next tool call.
MAX_RETRIES=3
COMPUTED_DIR="${PROJECTS_ROOT}/$(pwd | sed 's|[^a-zA-Z0-9-]|-|g')"

TRANSCRIPT=""
for attempt in $(seq 1 $MAX_RETRIES); do
  # Fast path: check computed project dir
  if [[ -d "$COMPUTED_DIR" ]]; then
    for f in $(ls -t "$COMPUTED_DIR"/*.jsonl 2>/dev/null | head -5); do
      if grep -q "$FINGERPRINT" "$f"; then
        TRANSCRIPT="$f"
        break
      fi
    done
  fi

  # Fallback: search the 10 most recently modified project dirs
  if [[ -z "$TRANSCRIPT" ]]; then
    for dir in $(ls -dt "$PROJECTS_ROOT"/*/ 2>/dev/null | head -10); do
      for f in $(ls -t "$dir"*.jsonl 2>/dev/null | head -3); do
        if grep -q "$FINGERPRINT" "$f"; then
          TRANSCRIPT="$f"
          break 2
        fi
      done
    done
  fi

  # Found it
  if [[ -n "$TRANSCRIPT" ]]; then
    break
  fi

  # Not found yet — wait for transcript flush (except on last attempt)
  if [[ $attempt -lt $MAX_RETRIES ]]; then
    sleep 1
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
