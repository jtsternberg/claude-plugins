#!/bin/bash
# Fetches Claude Code skills docs with 24hr cache.
# Cache: /tmp/claude-skill-docs-cache.md
# Expiry: /tmp/.claude-skill-docs-cache-exp

CACHE="/tmp/claude-skill-docs-cache.md"
EXPIRY="/tmp/.claude-skill-docs-cache-exp"
URL="https://code.claude.com/docs/en/skills.md"

needs_fetch=false

if [ ! -f "$EXPIRY" ] || [ ! -f "$CACHE" ]; then
	needs_fetch=true
elif [ "$(cat "$EXPIRY")" -lt "$(date +%s)" ] 2>/dev/null; then
	needs_fetch=true
fi

if [ "$needs_fetch" = true ]; then
	content=$(curl -sL "$URL")
	if [ -n "$content" ]; then
		echo "$content" > "$CACHE"
		echo $(( $(date +%s) + 86400 )) > "$EXPIRY"
	fi
fi

echo "$CACHE"
