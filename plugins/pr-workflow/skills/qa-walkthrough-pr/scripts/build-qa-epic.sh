#!/bin/bash
# =============================================================================
# Build a beads QA epic with tasks from a JSON test plan.
#
# Accepts a JSON array on stdin where each element has:
#   { "name": "...", "description": "...", "depends_on_index": null | <int> }
#
# depends_on_index is a 0-based index into the array (null = no dependency,
# i.e. the task is ready immediately after the epic's pre-setup).
#
# Usage:
#   echo '[...]' | build-qa-epic.sh <label> ["<short-description>"]
#
# Output:
#   JSON object with epic_id, task list with IDs, and dependency map.
# =============================================================================

LABEL="${1:?Usage: build-qa-epic.sh <label> [<short-description>]}"
DESC="${2:-$LABEL}"

# Read JSON plan from stdin
PLAN=$(cat)
if [[ -z "$PLAN" ]]; then
  echo '{"error": "No test plan provided on stdin"}' >&2
  exit 1
fi

TASK_COUNT=$(echo "$PLAN" | jq 'length')
if [[ "$TASK_COUNT" -lt 1 ]]; then
  echo '{"error": "Test plan is empty"}' >&2
  exit 1
fi

# Create the epic
EPIC_OUTPUT=$(bd create --title="QA: ${DESC}" \
  --description="Manual QA walkthrough for ${LABEL}" \
  --type=epic --priority=1 --json 2>/dev/null)

EPIC_ID=$(echo "$EPIC_OUTPUT" | jq -r '.id // empty')
if [[ -z "$EPIC_ID" ]]; then
  echo '{"error": "Failed to create epic", "output": '"$(echo "$EPIC_OUTPUT" | jq -Rs .)"'}' >&2
  exit 1
fi

echo "Created epic: $EPIC_ID" >&2

# Create tasks and collect IDs
declare -a TASK_IDS
for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK_NAME=$(echo "$PLAN" | jq -r ".[$i].name")
  TASK_DESC=$(echo "$PLAN" | jq -r ".[$i].description // \"\"")

  TASK_OUTPUT=$(bd create --title="$TASK_NAME" \
    --description="$TASK_DESC" \
    --type=task --priority=2 --json 2>/dev/null)

  TASK_ID=$(echo "$TASK_OUTPUT" | jq -r '.id // empty')
  if [[ -z "$TASK_ID" ]]; then
    echo "Warning: Failed to create task $i: $TASK_NAME" >&2
    TASK_IDS+=("FAILED")
    continue
  fi

  TASK_IDS+=("$TASK_ID")
  echo "Created task $i: $TASK_ID ($TASK_NAME)" >&2
done

# Set dependencies
DEP_RESULTS=()
for i in $(seq 0 $((TASK_COUNT - 1))); do
  DEP_IDX=$(echo "$PLAN" | jq -r ".[$i].depends_on_index // \"null\"")

  if [[ "$DEP_IDX" != "null" && "${TASK_IDS[$DEP_IDX]}" != "FAILED" && "${TASK_IDS[$i]}" != "FAILED" ]]; then
    bd dep add "${TASK_IDS[$i]}" "${TASK_IDS[$DEP_IDX]}" 2>/dev/null
    DEP_RESULTS+=("{\"task\": \"${TASK_IDS[$i]}\", \"depends_on\": \"${TASK_IDS[$DEP_IDX]}\"}")
    echo "Dependency: ${TASK_IDS[$i]} depends on ${TASK_IDS[$DEP_IDX]}" >&2
  fi
done

# Build output JSON
TASKS_JSON="["
for i in $(seq 0 $((TASK_COUNT - 1))); do
  [[ $i -gt 0 ]] && TASKS_JSON+=","
  TASK_NAME=$(echo "$PLAN" | jq -r ".[$i].name")
  TASKS_JSON+="{\"index\": $i, \"id\": \"${TASK_IDS[$i]}\", \"name\": $(echo "$TASK_NAME" | jq -Rs .)}"
done
TASKS_JSON+="]"

DEPS_JSON="[$(IFS=,; echo "${DEP_RESULTS[*]}")]"

echo "{\"epic_id\": \"$EPIC_ID\", \"tasks\": $TASKS_JSON, \"dependencies\": $DEPS_JSON}"
