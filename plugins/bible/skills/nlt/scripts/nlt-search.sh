#!/usr/bin/env bash
# =============================================================================
# NLT Bible Search
#
# Searches Scripture by keyword using the NLT API.
#
# Usage:
#   nlt-search.sh <query> [version]
#
# Examples:
#   nlt-search.sh "love one another"
#   nlt-search.sh "faith" KJV
# =============================================================================
set -euo pipefail

QUERY="${1:?Usage: nlt-search.sh <query> [version]}"
VERSION="${2:-NLT}"

if [ -z "${NLT_API_KEY:-}" ]; then
	echo "ERROR: NLT_API_KEY not set. Add to Claude global settings: env > NLT_API_KEY" >&2
	exit 1
fi

case "$VERSION" in
	NLT|NLTUK|NTV|KJV) ;;
	*) echo "ERROR: Unsupported version '$VERSION'. Use: NLT, NLTUK, NTV, or KJV" >&2; exit 1 ;;
esac

ENCODED_QUERY=$(printf '%s' "$QUERY" | sed 's/ /+/g')
URL="https://api.nlt.to/api/search?text=${ENCODED_QUERY}&version=${VERSION}&key=${NLT_API_KEY}"

RESPONSE=$(curl -sf "$URL") || {
	echo "ERROR: API search failed for query '$QUERY'" >&2
	exit 1
}

if [ -z "$RESPONSE" ]; then
	echo "No results found for '$QUERY'" >&2
	exit 0
fi

if command -v html-to-markdown &>/dev/null; then
	echo "$RESPONSE" | html-to-markdown
else
	echo "$RESPONSE"
fi
