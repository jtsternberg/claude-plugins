#!/usr/bin/env bash
# =============================================================================
# Transcript Path: derive a Claude Code session's JSONL transcript path from its
# working directory and session id.
#
# Claude Code writes each session to
#   <config-dir>/projects/<encoded-cwd>/<session-id>.jsonl
# where <config-dir> is one of claude-config-dirs.sh's dirs (~/.claude by default),
# where <encoded-cwd> is the cwd with EVERY non-alphanumeric char (path
# separators, dots, spaces) replaced by '-'. Verified against ~/.claude/projects/:
#   /Users/JT/.dotfiles              → -Users-JT--dotfiles
#   /Users/JT/Documents/Southport UDO → -Users-JT-Documents-Southport-UDO
#
# This is the single source of truth for that derivation — wait-for-session.sh
# and wait-for-response.sh both call it so the encoding never drifts between them.
#
# Usage:
#   transcript-path.sh --cwd <path> --session <session-id>
#   # → prints the absolute .jsonl path on stdout (exit 0)
#   # → exit 1 with a message on stderr if --cwd or --session is missing
# =============================================================================
set -euo pipefail

CWD=""
SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)     CWD="$2";     shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    *)         shift ;;
  esac
done

[[ -z "$CWD"     ]] && { echo "transcript-path.sh: --cwd required" >&2;     exit 1; }
[[ -z "$SESSION" ]] && { echo "transcript-path.sh: --session required" >&2; exit 1; }

ENCODED_CWD=$(printf '%s' "$CWD" | sed 's|[^a-zA-Z0-9]|-|g')
REL="projects/$ENCODED_CWD/$SESSION.jsonl"
# HOTLINE_CLAUDE_CONFIG_DIR: the caller already knows the receiver's config dir
# (send matched it in that dir's registry).
if [[ -n "${HOTLINE_CLAUDE_CONFIG_DIR:-}" ]]; then
  printf '%s/%s\n' "$HOTLINE_CLAUDE_CONFIG_DIR" "$REL"
  exit 0
fi
# Otherwise the dir that already holds this transcript, else the primary dir: a
# session that does not exist yet is being launched, and a launch writes there.
source "$(dirname "${BASH_SOURCE[0]}")/claude-config-dirs.sh"
HITS=() PRIMARY="" SEEN=$'\n'
while IFS= read -r d; do
  [[ -z "$PRIMARY" ]] && PRIMARY="$d"
  [[ -f "$d/$REL" ]] || continue
  REAL=$(hotline_claude_real_file "$d/$REL")
  [[ "$SEEN" == *$'\n'"$REAL"$'\n'* ]] && continue
  SEEN+="$REAL"$'\n'
  HITS+=("$d/$REL")
done < <(hotline_claude_config_dirs)
case ${#HITS[@]} in
  0) printf '%s/%s\n' "$PRIMARY" "$REL" ;;
  1) printf '%s\n' "${HITS[0]}" ;;
  *) echo "transcript-path.sh: ambiguous: $SESSION is in more than one Claude config dir: ${HITS[*]}" >&2; exit 1 ;;
esac
