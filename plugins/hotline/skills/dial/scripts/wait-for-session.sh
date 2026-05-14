#!/usr/bin/env bash
# =============================================================================
# Wait for Session: Poll until the remote session ID is available.
#
# Two modes, auto-detected from the call_dir contents:
#
#   Headless mode (no workspace_ref.txt): poll call_dir/session_id.txt at
#   1s intervals; cmux-call.sh and headless-call-async.sh write it themselves.
#
#   CMUX mode (workspace_ref.txt present): cmux-call-async.sh wrote
#   session_id_preset.txt but does NOT confirm claude actually booted —
#   under cmux access_mode=cmuxOnly, the script's own background poller
#   can't talk to cmux. This script (running as a child of the caller's
#   cmux-spawned bash) polls `cmux read-screen` for the Claude Code REPL
#   banner, then promotes session_id_preset.txt → session_id.txt as proof
#   the receiver is genuinely up.
#
# Prints the session ID to stdout on success.
#
# Exit codes:
#   0 — session ID found (printed to stdout)
#   1 — error (timeout, missing call_dir, or early failure)
#
# Usage:
#   wait-for-session.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

CALL_DIR="${1:-}"
TIMEOUT=""

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo '{"error":"Call directory not provided or does not exist"}' >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Mode detection. cmux mode gets a longer default timeout (60s) because we're
# waiting for the receiver claude REPL to actually boot, not just a file to
# appear. Headless mode keeps its existing 30s default.
CMUX_MODE=false
if [[ -f "$CALL_DIR/workspace_ref.txt" ]]; then
  CMUX_MODE=true
fi
if [[ -z "$TIMEOUT" ]]; then
  $CMUX_MODE && TIMEOUT=60 || TIMEOUT=30
fi

# Common early-fail check: if the launcher already wrote done+error.txt, bail.
check_early_fail() {
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    cat "$CALL_DIR/error.txt" >&2
    exit 1
  fi
}

if $CMUX_MODE; then
  WS_REF=$(cat "$CALL_DIR/workspace_ref.txt")
  if [[ ! -f "$CALL_DIR/session_id_preset.txt" ]]; then
    echo "CMUX call_dir missing session_id_preset.txt — launcher bug" >&2
    exit 1
  fi
  PRESET=$(cat "$CALL_DIR/session_id_preset.txt")
  ESC=$(printf '\x1b')

  ELAPSED=0
  while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
    check_early_fail
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      echo "Timed out waiting for Claude REPL to boot in cmux workspace ${WS_REF} (${TIMEOUT}s). cmux send succeeded but no 'Claude Code v' banner appeared on screen. Common causes: launch-script claude invocation is malformed (e.g. --allowedTools without a -- separator before the positional prompt), or the workspace lost its tty." >&2
      exit 1
    fi

    SCREEN=$(cmux read-screen --workspace "$WS_REF" --scrollback --lines 9999 \
      2>/dev/null || true)
    if [[ -n "$SCREEN" ]]; then
      CLEAN=$(echo "$SCREEN" | sed "s/${ESC}\[[0-9;]*[mGKHFJKsu]//g; s/${ESC}(B//g; s/\r//g")
      if echo "$CLEAN" | grep -qE 'Claude Code v|Welcome back'; then
        # Confirmed: claude REPL is up. Promote preset → session_id.txt.
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
  done

  cat "$CALL_DIR/session_id.txt"
  exit 0
fi

# Headless mode — original behavior.
ELAPSED=0
while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
  check_early_fail
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timed out waiting for session ID (${TIMEOUT}s)" >&2
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

cat "$CALL_DIR/session_id.txt"
