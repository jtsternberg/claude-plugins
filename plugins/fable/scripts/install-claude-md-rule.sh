#!/usr/bin/env bash
#
# install-claude-md-rule.sh — install (or refresh) a fable-plugin rule in the
# user's CLAUDE.md as a managed, idempotent block.
#
# Shared by the fable plugin's skills (think-like-fable, fable-delegate).
# Each rule is wrapped in marker comments; re-running replaces the block in
# place instead of duplicating it. A timestamped .bak backup is written
# before any modification.
#
# Usage:
#   install-claude-md-rule.sh <think-like-fable|fable-delegate> [--target <path>] [--check] [--remove]
#
#   --target <path>  CLAUDE.md to edit (default: ~/.claude/CLAUDE.md)
#   --check          Exit 0 if the rule is already installed, 1 if not. No writes.
#   --remove         Remove the managed block instead of installing it.

set -euo pipefail
trap 'exit 130' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

usage() { sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

RULE_ID="${1:-}"; shift || true
TARGET="$HOME/.claude/CLAUDE.md"
MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --check)  MODE="check"; shift ;;
    --remove) MODE="remove"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

skill_path() { echo "$PLUGIN_ROOT/skills/$1/SKILL.md"; }

case "$RULE_ID" in
  think-like-fable)
    RULE_TEXT="## Not on Fable? Think Like Fable

If you are the MAIN agent and running on a non-Fable Claude model (Opus, Sonnet): before starting substantive work (debugging, investigation, refactoring, anything with judgment calls about scope or autonomy), read $(skill_path think-like-fable) and adopt its stance: own the outcome, not the response."
    ;;
  fable-delegate)
    RULE_TEXT="## Running on Fable? Delegate the Doing

If you are the MAIN agent and running on the Fable model (claude-fable-5): read $(skill_path fable-delegate). You are the thinker/boss, not the doer — delegate execution (edits, searches, test runs, mechanical multi-step work) to Opus/Sonnet subagents via the Agent tool's model param, and keep Fable cycles for planning, judgment, review, and talking to the user."
    ;;
  *) echo "Unknown or missing rule id: '$RULE_ID'" >&2; usage >&2; exit 2 ;;
esac

BEGIN_MARK="<!-- BEGIN fable-plugin:$RULE_ID (managed by install-claude-md-rule.sh — edits inside will be overwritten) -->"
END_MARK="<!-- END fable-plugin:$RULE_ID -->"
BLOCK="$BEGIN_MARK
$RULE_TEXT
$END_MARK"

installed() { [ -f "$TARGET" ] && grep -qF "$BEGIN_MARK" "$TARGET"; }

if [ "$MODE" = "check" ]; then
  if installed; then echo "installed: $RULE_ID in $TARGET"; exit 0
  else echo "not installed: $RULE_ID in $TARGET"; exit 1; fi
fi

mkdir -p "$(dirname "$TARGET")"
touch "$TARGET"
BACKUP="$TARGET.$(date +%Y%m%d-%H%M%S).bak"
cp "$TARGET" "$BACKUP"

# Strip any existing managed block (BEGIN..END inclusive), then re-append
# unless removing. awk keeps everything outside the markers untouched.
TMP="$(mktemp)"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { skip = 1; next }
  index($0, e) { skip = 0; next }
  !skip { print }
' "$TARGET" > "$TMP"

if [ "$MODE" = "remove" ]; then
  if ! installed; then rm -f "$TMP" "$BACKUP"; echo "nothing to remove: $RULE_ID not in $TARGET"; exit 0; fi
  # Trim a single trailing blank line left behind by the removed block.
  printf '%s\n' "$(cat "$TMP")" > "$TARGET"
  rm -f "$TMP"
  echo "removed: $RULE_ID from $TARGET (backup: $BACKUP)"
  exit 0
fi

ACTION="installed"
installed && ACTION="updated"
{ cat "$TMP"; [ -s "$TMP" ] && echo; printf '%s\n' "$BLOCK"; } > "$TARGET"
rm -f "$TMP"
echo "$ACTION: $RULE_ID in $TARGET (backup: $BACKUP)"
