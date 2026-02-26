#!/usr/bin/env bash
set -euo pipefail

# Start a local HTTP server for a presentation HTML file.
# Serves from the directory containing the file, bound to localhost only.
#
# Usage: serve-local.sh <file.html>
# Output: Prints the URL and PID for use by the export workflow.
#         To stop: kill <PID>

FILE="${1:?Usage: serve-local.sh <file.html>}"

# Resolve to absolute path
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

if [ ! -f "$FILE" ]; then
  echo "ERROR: File not found: $FILE" >&2
  exit 1
fi

SERVE_DIR="$(dirname "$FILE")"
FILENAME="$(basename "$FILE")"

# Find an available port starting from 8000
PORT=8000
while lsof -i :"$PORT" >/dev/null 2>&1; do
  PORT=$((PORT + 1))
  if [ "$PORT" -gt 8099 ]; then
    echo "ERROR: No available port in range 8000-8099" >&2
    exit 1
  fi
done

# Start server in background, bound to localhost only
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE_DIR" >/dev/null 2>&1 &
SERVER_PID=$!

# Give server a moment to start
sleep 0.5

# Verify it started
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "ERROR: Server failed to start" >&2
  exit 1
fi

URL="http://127.0.0.1:${PORT}/${FILENAME}"

echo "URL=$URL"
echo "PID=$SERVER_PID"
echo "PORT=$PORT"
