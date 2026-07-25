#!/usr/bin/env bash
# session-start.sh — handoff plugin SessionStart hook (matcher: startup|resume)
#
# 1. Caches this session's identifiers (session_id, transcript_path, cwd) to
#    /tmp/claude-handoff/<claude-pid>.json so the handoff skill can embed them
#    in the handoff it writes later.
# 2. Scans the working directory for pending handoffs — HANDOFF*.md files and,
#    when beads is available, open issues titled "Handoff:" — and prints one
#    compact line per finding, suggesting /handoff:pickup-handoff <identifier>.
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

# --- cache session info keyed by the claude ancestor PID --------------------
# (ancestry-walk pattern borrowed from hotline's session-fingerprint.sh)
CLAUDE_PID=""
pid=$$
while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs 2>/dev/null || true)
  if [ "${comm##*/}" = "claude" ]; then
    CLAUDE_PID=$pid
    break
  fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
done

if [ -n "$CLAUDE_PID" ] && [ -n "$SESSION_ID" ]; then
  mkdir -p /tmp/claude-handoff 2>/dev/null || true
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}\n' \
    "$SESSION_ID" "$TRANSCRIPT" "$CWD" \
    > "/tmp/claude-handoff/${CLAUDE_PID}.json" 2>/dev/null || true
fi

# --- scan for pending handoffs ----------------------------------------------
findings=""
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

if command -v bd >/dev/null 2>&1 && [ -d "$CWD/.beads" ]; then
  bdout=$(bd -C "$CWD" list --status open,in_progress --title-contains "Handoff:" --flat --no-pager 2>/dev/null || true)
  while IFS= read -r line; do
    case "$line" in
      *Handoff:*) findings="${findings}- Handoff issue: ${line}
" ;;
    esac
  done <<EOF
$bdout
EOF
fi

if [ -n "$findings" ]; then
  printf 'Pending handoff(s) found in %s:\n' "$CWD"
  printf '%s' "$findings"
  printf 'To resume one, run /handoff:pickup-handoff <id-or-filename> — pass the identifier\n'
  printf 'from the list above so pickup resolves it directly instead of re-searching.\n'
fi

exit 0
