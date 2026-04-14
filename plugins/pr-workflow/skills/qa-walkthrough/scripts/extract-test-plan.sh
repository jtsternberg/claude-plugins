#!/bin/bash
# =============================================================================
# Extract a testing section from a PR description, git diff, or stdin.
#
# Modes:
#   extract-test-plan.sh <pr-number>       — Parse PR description for test plan
#   extract-test-plan.sh --from-diff       — Summarize changes from git diff
#   extract-test-plan.sh --from-diff=REF   — Diff against a specific ref (default: main)
#   extract-test-plan.sh --from-stdin      — Read test context from stdin
#
# Output:
#   The raw markdown/text of the testing context, or nothing if not found.
#   Exit code 0 if found, 1 if no testing section exists, 2 on errors.
# =============================================================================

MODE="pr"
PR=""
DIFF_REF="main"

case "${1:-}" in
  --from-diff=*)
    MODE="diff"
    DIFF_REF="${1#--from-diff=}"
    ;;
  --from-diff)
    MODE="diff"
    ;;
  --from-stdin)
    MODE="stdin"
    ;;
  "")
    echo "Usage: extract-test-plan.sh <pr-number> | --from-diff[=REF] | --from-stdin" >&2
    exit 2
    ;;
  *)
    MODE="pr"
    PR="$1"
    ;;
esac

if [[ "$MODE" == "pr" ]]; then
  BODY=$(gh pr view "$PR" --json body -q .body 2>/dev/null)
  if [[ -z "$BODY" ]]; then
    echo "Error: Could not fetch PR #${PR}" >&2
    exit 2
  fi

  # Match common test plan headings, grab content until the next ## heading
  SECTION=$(echo "$BODY" | sed -n '/^## \(Testing Procedure\|Test Plan\|How to Test\|Testing\|Manual Testing\)/I,/^## /p' | head -n -1)

  if [[ -z "$SECTION" ]]; then
    echo "No testing section found in PR #${PR} description." >&2
    exit 1
  fi

  echo "$SECTION"

elif [[ "$MODE" == "diff" ]]; then
  # Check for staged changes first, then branch diff
  STAGED=$(git diff --cached --stat 2>/dev/null)
  BRANCH_DIFF=$(git diff "${DIFF_REF}...HEAD" --stat 2>/dev/null)

  if [[ -z "$STAGED" && -z "$BRANCH_DIFF" ]]; then
    echo "No changes found (checked staged and ${DIFF_REF}...HEAD)." >&2
    exit 1
  fi

  echo "## Changed Files"
  echo ""
  if [[ -n "$STAGED" ]]; then
    echo "### Staged Changes"
    echo '```'
    echo "$STAGED"
    echo '```'
    echo ""
    echo "### Staged Diff"
    echo '```'
    git diff --cached 2>/dev/null
    echo '```'
    echo ""
  fi
  if [[ -n "$BRANCH_DIFF" ]]; then
    echo "### Branch Changes (vs ${DIFF_REF})"
    echo '```'
    echo "$BRANCH_DIFF"
    echo '```'
    echo ""
    echo "### Branch Diff"
    echo '```'
    git diff "${DIFF_REF}...HEAD" 2>/dev/null
    echo '```'
  fi

elif [[ "$MODE" == "stdin" ]]; then
  BODY=$(cat)
  if [[ -z "$BODY" ]]; then
    echo "No input provided on stdin." >&2
    exit 1
  fi
  echo "$BODY"
fi
