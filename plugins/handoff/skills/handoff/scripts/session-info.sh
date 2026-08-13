#!/usr/bin/env bash
# session-info.sh — print this session's cached info as one JSON line:
#   {"session_id":"...","transcript_path":"...","cwd":"..."}
#
# The handoff plugin's SessionStart and PostCompact hooks write the cache to
# /tmp/claude-handoff/<agent-pid>.json. This script walks its own process
# ancestry to find the Claude Code or Codex PID (same approach as hotline's
# session-fingerprint.sh) and prints the matching cache file.
#
# Exits 0 silently on any miss — hooks not installed (standalone skill
# install), cache expired, or no claude ancestor. Callers treat empty
# output as "session info unavailable".

pid=$$
while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs 2>/dev/null || true)
  # macOS `ps -o comm=` returns the full executable path; Linux returns the
  # bare command name. Strip the path prefix so the check works on both.
  case "${comm##*/}" in
  claude|codex)
    # CLAUDE_HANDOFF_CACHE_DIR must match what the SessionStart/PostCompact
    # hooks wrote with (default /tmp/claude-handoff). Tests set it to a scratch
    # dir so a direct hook run can't poison the live cache (claude-plugins-d4ux).
    cache="${CLAUDE_HANDOFF_CACHE_DIR:-/tmp/claude-handoff}/${pid}.json"
    [ -f "$cache" ] && cat "$cache" 2>/dev/null
    exit 0
    ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
done

exit 0
