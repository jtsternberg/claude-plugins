#!/usr/bin/env bash
# =============================================================================
# Transcript Path: derive a Claude Code session's JSONL transcript path from its
# working directory and session id.
#
# Claude Code writes each session to
#   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
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
printf '%s/.claude/projects/%s/%s.jsonl\n' "$HOME" "$ENCODED_CWD" "$SESSION"
