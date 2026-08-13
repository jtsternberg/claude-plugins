#!/usr/bin/env bash
# session-start.sh — handoff plugin SessionStart hook (matcher: startup|resume)
#
# 1. Caches this session's identifiers (session_id, transcript_path, cwd) to
#    /tmp/claude-handoff/<claude-pid>.json so the handoff skill can embed them
#    in the handoff it writes later.
# 2. Scans the working directory for pending handoffs — HANDOFF*.md files and,
#    when beads is available, open issues titled "pending-handoff:" — and prints one
#    compact line per finding, suggesting the harness-specific pickup command.
#    Each finding line carries its own identifier (bd id, or filename) so pickup
#    can be invoked with it and resolve directly instead of re-searching.
#
# Prints NOTHING when there is nothing to report. Never fails: every error
# path degrades silently and the script always exits 0.

# --- read stdin (may be empty or malformed JSON) ----------------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

PY=$(command -v python3 || command -v python || true)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMMAND_GENERATOR="$SCRIPT_DIR/../../skills/handoff/scripts/generate-command.sh"

render_command() {
  action=$1
  # Both markers (or neither) would make the command syntax guesswork. Leave
  # an explicit neutral instruction rather than emitting the wrong client form.
  if { [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -n "${CODEX_THREAD_ID:-}" ]; } || \
    { [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -z "${CODEX_THREAD_ID:-}" ]; }; then
    return 1
  fi
  if [ "$#" -eq 1 ]; then
    "$COMMAND_GENERATOR" --action "$action" 2>/dev/null
  else
    "$COMMAND_GENERATOR" --action "$action" "$2" 2>/dev/null
  fi
}

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
    # Fallback: naive extraction, fine for the flat JSON hooks receive.
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

# --- cache session info keyed by the active harness ancestor PID ------------
# Claude Code and Codex both execute plugin hooks as child processes. Keep the
# existing cache directory for compatibility, but make its key harness-neutral.
AGENT_PID=""
pid=$$
while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs 2>/dev/null || true)
  case "${comm##*/}" in
    claude|codex) AGENT_PID=$pid; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
done

# CLAUDE_HANDOFF_CACHE_DIR overrides the cache location. The default is shared
# by every session on the box, keyed by the ancestor PID — so a test that runs
# this hook directly (its own ancestry still reaches the real claude/codex PID)
# would clobber the LIVE session's cache with fixture values, and session-info.sh
# would then hand the next agent a poisoned transcript target (claude-plugins-d4ux).
# Tests point this at a scratch dir; session-info.sh reads the same variable.
HANDOFF_CACHE_DIR="${CLAUDE_HANDOFF_CACHE_DIR:-/tmp/claude-handoff}"

if [ -n "$AGENT_PID" ] && [ -n "$SESSION_ID" ]; then
  mkdir -p "$HANDOFF_CACHE_DIR" 2>/dev/null || true
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}\n' \
    "$SESSION_ID" "$TRANSCRIPT" "$CWD" \
    > "$HANDOFF_CACHE_DIR/${AGENT_PID}.json" 2>/dev/null || true
fi

# --- scan for pending handoffs ----------------------------------------------
findings=""   # confident: HANDOFF*.md files + issues with the `pending-handoff:` prefix
maybes=""     # weaker: issues that merely mention a handoff somewhere in the title
now=$(date +%s 2>/dev/null || echo "")

for f in "$CWD"/HANDOFF*.md; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  detail=""

  # Age from mtime (BSD stat first, then GNU stat).
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
  if [ -n "$mtime" ] && [ -n "$now" ]; then
    secs=$(( now - mtime ))
    if [ "$secs" -lt 3600 ]; then detail="$(( secs / 60 ))m old"
    elif [ "$secs" -lt 86400 ]; then detail="$(( secs / 3600 ))h old"
    else detail="$(( secs / 86400 ))d old"; fi
  fi

  # Commits since the doc's Anchor SHA (line like "- HEAD: `abc1234...`").
  sha=$(sed -n 's/.*HEAD:[^0-9a-f]*\([0-9a-f]\{7,40\}\).*/\1/p' "$f" 2>/dev/null | head -1)
  if [ -n "$sha" ]; then
    n=$(git -C "$CWD" rev-list --count "${sha}..HEAD" 2>/dev/null || true)
    if [ -n "$n" ]; then
      [ -n "$detail" ] && detail="${detail}, "
      detail="${detail}${n} commits since its anchor"
    fi
  fi

  [ -n "$detail" ] && detail=" (${detail})"
  findings="${findings}- Handoff file: ${name}${detail}
"
done

# A handoff issue is titled with the `pending-handoff: ` PREFIX (references/beads.md).
# The marker is deliberately unusual: a plain `Handoff:` prefix collided with ordinary
# issues about handoffs, and `bd --title-contains` matches case-insensitively and
# anywhere in the title, so those collisions were awkward to filter after the fact.
#
# Still sort rather than discard. Dropping a real handoff is the worse failure — a
# cold start is exactly what this hook exists to prevent — but announcing an ordinary
# issue as a pending handoff trains everyone to ignore the notice. Prefix matches are
# reported as handoffs; anything else the query returned is surfaced separately as a
# weaker signal rather than thrown away.
if command -v bd >/dev/null 2>&1 && [ -d "$CWD/.beads" ]; then
  bdout=$(bd -C "$CWD" list --status open,in_progress --title-contains "pending-handoff" --flat --no-pager 2>/dev/null || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # --flat format: "<glyph> <id> [<pri>] [<type>] - <title>". Strip through the
    # first " - " to isolate the title; with no separator, treat the whole line as
    # the title rather than dropping the row.
    case "$line" in
      *" - "*) title="${line#* - }" ;;
      *) title="$line" ;;
    esac
    lower=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      pending-handoff:*) findings="${findings}- Handoff issue: ${line}
" ;;
      *) maybes="${maybes}- Mentions a handoff: ${line}
" ;;
    esac
  done <<EOF
$bdout
EOF
fi

if [ -n "$findings" ]; then
  printf 'Pending handoff(s) found in %s:\n' "$CWD"
  printf '%s' "$findings"
  [ -n "$maybes" ] && printf 'Also open, titled like work ABOUT handoffs rather than a handoff itself:\n%s' "$maybes"
  if pickup_command=$(render_command pickup-handoff); then
    printf 'To resume one, run %s <id-or-filename> — pass the identifier from the list above so pickup resolves it directly instead of re-searching.\n' "$pickup_command"
  else
    printf "%s\n" "To resume one, invoke the installed handoff pickup skill with <id-or-filename> using this client's skill syntax; the hook could not determine whether this is Claude Code or Codex."
  fi
elif [ -n "$maybes" ]; then
  # Nothing carries the `pending-handoff:` prefix, so don't claim one — but
  # don't stay silent either, in case one was titled by hand without the prefix.
  printf 'No handoff matched the `pending-handoff:` prefix in %s, but these are open:\n' "$CWD"
  printf '%s' "$maybes"
  if pickup_command=$(render_command pickup-handoff); then
    printf 'If one of those IS the handoff, resume it with %s <id>.\n' "$pickup_command"
  else
    printf "%s\n" "If one of those IS the handoff, invoke the installed handoff pickup skill with <id> using this client's skill syntax; the hook could not determine whether this is Claude Code or Codex."
  fi
fi

exit 0
