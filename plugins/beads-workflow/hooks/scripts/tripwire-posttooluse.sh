#!/usr/bin/env bash
#
# tripwire-posttooluse.sh — beads-workflow PostToolUse hook (Edit|Write|MultiEdit).
#
# The edit-time trigger the tripwire mechanism was always meant to be. When an
# agent edits a file that an open/blocked bead watches (via that bead's
# `tripwire-paths:` line), inject a one-line reminder into the model's context so
# the parked knowledge surfaces at the moment of the edit — not only if someone
# later remembers to run a review scan.
#
# CLAUDE-PRIMARY. Under Codex, PostToolUse is a schema-backed event and hook
# stdout can reach the model, but PostToolUse-specific context injection is
# unverified there (docs/codex/hooks-under-codex.md; probe: claude-plugins-c34o),
# and Codex gates hooks behind first-run trust. The tripwire-scan skill is the
# harness-independent floor; this hook is the Claude enhancement.
#
# Noise control: fires at most ONCE per file per session. The throttle is keyed
# off the real session_id from the hook payload (never cwd/pid), so it holds for
# the life of the session and does not leak across sessions on the same box.
#
# Never fails: every error path degrades to silence and the hook exits 0.

INPUT=""
[ -t 0 ] || INPUT=$(cat 2>/dev/null || true)

PY=$(command -v python3 || command -v python || true)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MATCH="$SCRIPT_DIR/../../scripts/tripwire-match.sh"
[ -f "$MATCH" ] || exit 0

json_get() {
  # Best-effort string extraction from the flat-ish hook payload. Supports one
  # level of nesting as "a.b" (for tool_input.file_path).
  key=$1 val=""
  if [ -n "$PY" ] && [ -n "$INPUT" ]; then
    val=$(printf '%s' "$INPUT" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    cur = d
    for part in sys.argv[1].split("."):
        cur = cur.get(part) if isinstance(cur, dict) else None
    print(cur if isinstance(cur, str) else "")
except Exception:
    pass' "$key" 2>/dev/null || true)
  fi
  printf '%s' "$val"
}

SESSION_ID=$(json_get session_id)
CWD=$(json_get cwd)
FILE=$(json_get tool_input.file_path)

[ -n "$FILE" ] || exit 0
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD=$(pwd)

# --- throttle: once per file per session, keyed off the real session_id ------
STATE_ROOT="${BEADS_TRIPWIRE_STATE_DIR:-${TMPDIR:-/tmp}/beads-tripwire}"
# A session with no id can't be throttled correctly; use a stable placeholder so
# it still fires once rather than every edit.
SID="${SESSION_ID:-no-session}"
if [ -n "$PY" ]; then
  KEY=$(printf '%s' "$FILE" | "$PY" -c 'import hashlib,sys;print(hashlib.sha1(sys.stdin.read().encode()).hexdigest())' 2>/dev/null || true)
fi
[ -n "${KEY:-}" ] || KEY=$(printf '%s' "$FILE" | tr '/ .' '___')
MARKER_DIR="$STATE_ROOT/$SID"
MARKER="$MARKER_DIR/$KEY"
[ -e "$MARKER" ] && exit 0
mkdir -p "$MARKER_DIR" 2>/dev/null && : > "$MARKER" 2>/dev/null || true

# --- match the edited file against open/blocked beads' tripwires -------------
HITS=$(cd "$CWD" 2>/dev/null && bash "$MATCH" check "$FILE" 2>/dev/null || true)
[ -n "$HITS" ] || exit 0

# Build the reminder. Each hit line: <bead-id>\t<path>\t<kind>\t<why>.
MSG=$(printf '%s\n' "$HITS" | awk -F'\t' '
  NF>=4 { ids=ids sep $1; sep=", "; whys=whys "\n  • " $1 " — " $4; path=$2 }
  END {
    printf "TRIPWIRE — %s is watched by parked bead(s) %s.%s\n", path, ids, whys
    print "This code carries contingent knowledge recorded in those beads. Run bd show <id> before finishing this edit, then act on it, consciously defer, or close the bead. Claim a bead in_progress to silence its tripwire."
  }')

if [ -n "$PY" ]; then
  printf '%s' "$MSG" | "$PY" -c '
import json, sys
msg = sys.stdin.read()
print(json.dumps({"hookSpecificOutput":
    {"hookEventName":"PostToolUse","additionalContext":msg},
    "suppressOutput":True}))' 2>/dev/null && exit 0
fi

# Fallback: plain stdout (also reaches the model per hooks-under-codex.md).
printf '%s\n' "$MSG"
exit 0
