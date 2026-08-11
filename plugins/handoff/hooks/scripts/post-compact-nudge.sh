#!/usr/bin/env bash
# post-compact-nudge.sh — handoff plugin PostCompact hook (matcher: manual|auto)
#
# Runs right after a context compaction. Refreshes the session-info cache
# (the transcript path can change across resumes) and prints a one-line nudge
# that the harness-specific handoff command can bank fresh context while it is
# still fresh.
#
# Never fails: every error path degrades silently and the script exits 0.

# --- read stdin (may be empty or malformed JSON) ----------------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

PY=$(command -v python3 || command -v python || true)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMMAND_GENERATOR="$SCRIPT_DIR/../../skills/handoff/scripts/generate-command.sh"

if { [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -n "${CODEX_THREAD_ID:-}" ]; } || \
  { [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -z "${CODEX_THREAD_ID:-}" ]; }; then
  handoff_command="the installed handoff skill using this client's skill syntax"
else
  handoff_command=$("$COMMAND_GENERATOR" --action handoff 2>/dev/null || true)
  [ -n "$handoff_command" ] || handoff_command="the installed handoff skill using this client's skill syntax"
fi

json_get() {
  # json_get <key> — best-effort string value extraction from $INPUT.
  key=$1
  val=""
  if [ -n "$PY" ] && [ -n "$INPUT" ]; then
    val=$(printf '%s' "$INPUT" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get(sys.argv[1], "")
    if isinstance(v, str):
        print(v)
except Exception:
    pass' "$key" 2>/dev/null || true)
  fi
  if [ -z "$val" ] && [ -n "$INPUT" ]; then
    val=$(printf '%s' "$INPUT" | tr -d '\n' \
      | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null \
      | head -1 || true)
  fi
  printf '%s' "$val"
}

SESSION_ID=$(json_get session_id)
TRANSCRIPT=$(json_get transcript_path)
CWD=$(json_get cwd)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD=$(pwd)

# --- refresh the session cache keyed by the active harness ancestor PID -----
AGENT_PID=""
pid=$$
while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs 2>/dev/null || true)
  case "${comm##*/}" in
    claude|codex) AGENT_PID=$pid; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
done

if [ -n "$AGENT_PID" ] && [ -n "$SESSION_ID" ]; then
  mkdir -p /tmp/claude-handoff 2>/dev/null || true
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}\n' \
    "$SESSION_ID" "$TRANSCRIPT" "$CWD" \
    > "/tmp/claude-handoff/${AGENT_PID}.json" 2>/dev/null || true
fi

printf 'Context was just compacted. If mid-task, running %s now will bank fresh context into a handoff before details fade.\n' "$handoff_command"

exit 0
