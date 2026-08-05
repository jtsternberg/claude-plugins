#!/usr/bin/env bash
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

check_file() {
	local file="$1"
	grep -Fq '${CLAUDE_SKILL_DIR}/' "$file" && return 1
	grep -Fq '${CLAUDE_PLUGIN_ROOT}/' "$file" && return 1
	grep -Eq '\$\{CLAUDE_SKILL_DIR[^}]*\}/\.\./\.\.|\$(SKILL_DIR|PLUGIN_ROOT)/\.\./\.\.' "$file" && return 1
	grep -Eq '(\$HOME|~)/\.claude/plugins/' "$file" && return 1
	return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' 'bash ${CLAUDE_SKILL_DIR}/scripts/run.sh' >"$TMP/direct-skill.md"
if check_file "$TMP/direct-skill.md"; then fail 'rejects direct CLAUDE_SKILL_DIR paths'; else pass 'rejects direct CLAUDE_SKILL_DIR paths'; fi

printf '%s\n' 'node "${CLAUDE_PLUGIN_ROOT}/scripts/run.mjs"' >"$TMP/direct-plugin.md"
if check_file "$TMP/direct-plugin.md"; then fail 'rejects direct CLAUDE_PLUGIN_ROOT paths'; else pass 'rejects direct CLAUDE_PLUGIN_ROOT paths'; fi

printf '%s\n' 'bash "$SKILL_DIR/../../scripts/run.sh"' >"$TMP/traversal.md"
if check_file "$TMP/traversal.md"; then fail 'rejects skill-root traversal'; else pass 'rejects skill-root traversal'; fi

printf '%s\n' 'bash ~/.claude/plugins/cache/example/run.sh' >"$TMP/claude-cache.md"
if check_file "$TMP/claude-cache.md"; then fail 'rejects hardcoded Claude plugin-cache paths'; else pass 'rejects hardcoded Claude plugin-cache paths'; fi

printf '%s\n' 'SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute skill directory>}"' 'bash "$SKILL_DIR/scripts/run.sh"' >"$TMP/fallback.md"
if check_file "$TMP/fallback.md"; then pass 'accepts the dual-harness fallback'; else fail 'accepts the dual-harness fallback'; fi

violations=0
while IFS= read -r file; do
	case "$file" in
		*/fable/*|*/README.md) continue ;;
	esac
	if ! check_file "$file"; then
		printf '  violation: %s\n' "${file#"$REPO"/}"
		violations=$((violations + 1))
	fi
done < <(find "$REPO/plugins" -type f -name '*.md' \( -path '*/skills/*' -o -path '*/references/*' \) -print)

if [[ $violations -eq 0 ]]; then
	pass 'model-read plugin Markdown has no unresolved runtime paths'
else
	fail "model-read plugin Markdown has no unresolved runtime paths ($violations files)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
