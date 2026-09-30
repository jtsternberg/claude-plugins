#!/bin/bash
# =============================================================================
# Clean up QA beads tasks and epic after a successful walkthrough.
#
# Lists all tasks under the epic, shows what will be deleted, then deletes.
# Designed to be called by Claude after user confirmation — no interactive
# prompt (use --dry-run to preview without deleting).
#
# Usage:
#   qa-cleanup.sh <epic-id> [--dry-run]
#
# Output:
#   List of deleted task IDs, or preview if --dry-run.
# =============================================================================

EPIC_ID="${1:?Usage: qa-cleanup.sh <epic-id> [--dry-run]}"
DRY_RUN=""
[[ "$2" == "--dry-run" ]] && DRY_RUN=1

# Tasks are linked by --parent (see build-qa-epic.sh). --all because a finished
# walkthrough has closed them, which the default list hides; --limit 0 lifts the
# 50-row cap.
TASKS=$(bd list --parent "$EPIC_ID" --all --limit 0 --json 2>/dev/null | jq -r '.[].id')

if [[ -z "$TASKS" ]]; then
  echo "No tasks found under epic $EPIC_ID" >&2
  # Still try to delete the epic itself
  TASKS=""
fi

ALL_IDS="$TASKS $EPIC_ID"
COUNT=$(echo "$ALL_IDS" | wc -w | tr -d ' ')

if [[ -n "$DRY_RUN" ]]; then
  echo "Would delete $COUNT items:"
  for id in $ALL_IDS; do
    echo "  - $id"
  done
  exit 0
fi

echo "Deleting $COUNT items..." >&2
# shellcheck disable=SC2086
if ! bd delete $ALL_IDS --force >/dev/null; then
  echo "bd delete failed; some QA items may remain" >&2
  exit 1
fi

echo "Cleaned up $COUNT QA items (epic: $EPIC_ID)" >&2
