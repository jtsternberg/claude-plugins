#!/usr/bin/env bash
# =============================================================================
# NLT Bible Passage Lookup
#
# Fetches Bible passages from the NLT API with env var validation,
# URL encoding, and html-to-markdown conversion.
#
# Usage:
#   nlt-lookup.sh <reference> [version]
#
# Examples:
#   nlt-lookup.sh "John 3:16-17"
#   nlt-lookup.sh "Romans 8:28-30" KJV
#   nlt-lookup.sh "Psalm 23;Psalm 91"
# =============================================================================
set -euo pipefail

REF="${1:?Usage: nlt-lookup.sh <reference> [version]}"
VERSION="${2:-NLT}"

if [ -z "${NLT_API_KEY:-}" ]; then
	echo "ERROR: NLT_API_KEY not set. Add to Claude global settings: env > NLT_API_KEY" >&2
	exit 1
fi

# Validate version
case "$VERSION" in
	NLT|NLTUK|NTV|KJV) ;;
	*) echo "ERROR: Unsupported version '$VERSION'. Use: NLT, NLTUK, NTV, or KJV" >&2; exit 1 ;;
esac

ENCODED_REF=$(printf '%s' "$REF" | sed 's/ /+/g')
URL="https://api.nlt.to/api/passages?ref=${ENCODED_REF}&version=${VERSION}&key=${NLT_API_KEY}"

RESPONSE=$(curl -sf "$URL") || {
	echo "ERROR: API request failed for reference '$REF'" >&2
	exit 1
}

if [ -z "$RESPONSE" ]; then
	echo "ERROR: Empty response — check that '$REF' is a valid Bible reference" >&2
	exit 1
fi

if command -v html-to-markdown &>/dev/null; then
	echo "$RESPONSE" | html-to-markdown
else
	# No html-to-markdown available — output raw HTML for Claude to parse directly
	echo "$RESPONSE"
fi
