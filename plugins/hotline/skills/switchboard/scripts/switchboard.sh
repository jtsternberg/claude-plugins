#!/usr/bin/env bash
# =============================================================================
# Hotline Switchboard: start/stop/status for the live dashboard server
#
# Read-only viewer of hotline conversations. Serves server.js (zero-dep Node)
# on localhost and opens it in the browser.
#
# Usage:
#   switchboard.sh start [--port=4160] [--no-open]
#   switchboard.sh stop
#   switchboard.sh status
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" || -z "${1:-}" ]]; then
  echo "Usage: switchboard.sh start [--port=4160] [--no-open] | stop | status"
  echo ""
  echo "Live read-only dashboard of hotline conversations."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_JS="${SCRIPT_DIR}/server.js"
STATE_DIR="$HOME/.agents-hotline"
PID_FILE="${STATE_DIR}/switchboard.pid"
LOG_FILE="${STATE_DIR}/switchboard.log"

CMD="$1"
shift || true

PORT="${HOTLINE_SWITCHBOARD_PORT:-4160}"
OPEN=1
for arg in "$@"; do
  case "$arg" in
    --port=*) PORT="${arg#--port=}" ;;
    --no-open) OPEN=0 ;;
  esac
done

running_pid() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}

open_url() {
  local url="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then open "$url"; else xdg-open "$url" 2>/dev/null || true; fi
}

case "$CMD" in
  start)
    if ! command -v node >/dev/null 2>&1; then
      echo '{"status":"error","message":"node not found — the switchboard server requires Node.js"}'
      exit 1
    fi
    if PID=$(running_pid); then
      URL="http://127.0.0.1:${PORT}"
      [[ $OPEN -eq 1 ]] && open_url "$URL"
      echo "{\"status\":\"already_running\",\"pid\":${PID},\"url\":\"${URL}\"}"
      exit 0
    fi
    mkdir -p "$STATE_DIR"
    nohup node "$SERVER_JS" --port="$PORT" >> "$LOG_FILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PID_FILE"
    sleep 0.5
    if ! kill -0 "$PID" 2>/dev/null; then
      rm -f "$PID_FILE"
      echo "{\"status\":\"error\",\"message\":\"server failed to start — see ${LOG_FILE}\"}"
      exit 1
    fi
    URL="http://127.0.0.1:${PORT}"
    [[ $OPEN -eq 1 ]] && open_url "$URL"
    echo "{\"status\":\"started\",\"pid\":${PID},\"url\":\"${URL}\",\"log\":\"${LOG_FILE}\"}"
    ;;
  stop)
    if PID=$(running_pid); then
      kill "$PID" 2>/dev/null || true
      rm -f "$PID_FILE"
      echo "{\"status\":\"stopped\",\"pid\":${PID}}"
    else
      echo '{"status":"not_running"}'
    fi
    ;;
  status)
    if PID=$(running_pid); then
      echo "{\"status\":\"running\",\"pid\":${PID},\"url\":\"http://127.0.0.1:${PORT}\"}"
    else
      echo '{"status":"not_running"}'
    fi
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
esac
