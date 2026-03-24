#!/bin/bash
# =============================================================================
# Extract the testing section from a GitHub PR description.
#
# Looks for common test plan headings (## Testing, ## Test Plan, etc.) and
# prints everything from that heading until the next ## heading.
#
# Usage:
#   extract-test-plan.sh <pr-number>
#
# Output:
#   The raw markdown of the testing section, or nothing if not found.
#   Exit code 0 if found, 1 if no testing section exists.
# =============================================================================

PR="${1:?Usage: extract-test-plan.sh <pr-number>}"

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
