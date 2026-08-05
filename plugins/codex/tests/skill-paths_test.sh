#!/usr/bin/env bash
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

check_file() {
	local file="$1"
	grep -Eq '\$\{CLAUDE_(SKILL_DIR|PLUGIN_ROOT):-' "$file" && return 1
	grep -Eq '\$\{CLAUDE_SKILL_DIR[^}]*\}/\.\./\.\.|\$(SKILL_DIR|PLUGIN_ROOT)/\.\./\.\.' "$file" && return 1
	grep -Eq '(\$HOME|~)/\.claude/plugins/' "$file" && return 1
	return 0
}

check_dynamic_file() {
	local file="$1"
	awk '
		BEGIN { fenced = 0; bad = 0 }
		/^[[:space:]]*```!/ { fenced = 1; next }
		fenced && /^[[:space:]]*```[[:space:]]*$/ { fenced = 0; next }
		{
			dynamic = fenced || index($0, "!`") > 0
			if (dynamic && ($0 ~ /\$\{CLAUDE_[^}]*:-/ || $0 ~ /<[^>]*(path|directory)[^>]*>/)) {
				bad = 1
			}
		}
		END { exit bad ? 1 : 0 }
	' "$file"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' 'bash ${CLAUDE_SKILL_DIR}/scripts/run.sh' >"$TMP/direct-skill.md"
if check_file "$TMP/direct-skill.md"; then pass 'accepts exact CLAUDE_SKILL_DIR tokens'; else fail 'accepts exact CLAUDE_SKILL_DIR tokens'; fi

printf '%s\n' 'node "${CLAUDE_PLUGIN_ROOT}/scripts/run.mjs"' >"$TMP/direct-plugin.md"
if check_file "$TMP/direct-plugin.md"; then pass 'accepts exact CLAUDE_PLUGIN_ROOT tokens'; else fail 'accepts exact CLAUDE_PLUGIN_ROOT tokens'; fi

printf '%s\n' 'bash "$SKILL_DIR/../../scripts/run.sh"' >"$TMP/traversal.md"
if check_file "$TMP/traversal.md"; then fail 'rejects skill-root traversal'; else pass 'rejects skill-root traversal'; fi

printf '%s\n' 'bash ~/.claude/plugins/cache/example/run.sh' >"$TMP/claude-cache.md"
if check_file "$TMP/claude-cache.md"; then fail 'rejects hardcoded Claude plugin-cache paths'; else pass 'rejects hardcoded Claude plugin-cache paths'; fi

printf '%s\n' 'SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute skill directory>}"' 'bash "$SKILL_DIR/scripts/run.sh"' >"$TMP/fallback.md"
if check_file "$TMP/fallback.md"; then fail 'rejects default-wrapped CLAUDE path tokens'; else pass 'rejects default-wrapped CLAUDE path tokens'; fi

printf '%s\n' '```!' 'bash "${CLAUDE_SKILL_DIR}/scripts/run.sh"' '```' >"$TMP/dynamic-exact.md"
if check_dynamic_file "$TMP/dynamic-exact.md"; then pass 'accepts exact tokens in dynamic context'; else fail 'accepts exact tokens in dynamic context'; fi

printf '%s\n' '!`SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute skill directory>}"; bash "$SKILL_DIR/scripts/run.sh"`' >"$TMP/dynamic-placeholder.md"
if check_dynamic_file "$TMP/dynamic-placeholder.md"; then fail 'rejects placeholders in inline dynamic context'; else pass 'rejects placeholders in inline dynamic context'; fi

printf '%s\n' '```!' 'PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-<absolute plugin directory>}"' 'bash "$PLUGIN_ROOT/scripts/run.sh"' '```' >"$TMP/dynamic-fenced-placeholder.md"
if check_dynamic_file "$TMP/dynamic-fenced-placeholder.md"; then fail 'rejects placeholders in fenced dynamic context'; else pass 'rejects placeholders in fenced dynamic context'; fi

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
	pass 'model-read plugin Markdown uses mechanically resolvable runtime paths'
else
	fail "model-read plugin Markdown uses mechanically resolvable runtime paths ($violations files)"
fi

dynamic_violations=0
while IFS= read -r file; do
	if ! check_dynamic_file "$file"; then
		printf '  dynamic violation: %s\n' "${file#"$REPO"/}"
		dynamic_violations=$((dynamic_violations + 1))
	fi
done < <(find "$REPO/plugins" -type f -name 'SKILL.md' -print)

if [[ $dynamic_violations -eq 0 ]]; then
	pass 'dynamic context contains no model-resolved path placeholders'
else
	fail "dynamic context contains no model-resolved path placeholders ($dynamic_violations files)"
fi

hotline_docs=(
	"$REPO/plugins/hotline/README.md"
	"$REPO/plugins/hotline/skills/dial/SKILL.md"
	"$REPO/plugins/hotline/skills/ringing/SKILL.md"
)
if grep -Eq '/hotline-ringing([[:space:]]|\[)' "${hotline_docs[@]}"; then
	fail 'Hotline runtime prompts use the namespaced Claude invocation'
elif grep -Fq '/hotline:hotline-ringing' "${hotline_docs[@]}"; then
	pass 'Hotline runtime prompts use the namespaced Claude invocation'
else
	fail 'Hotline runtime prompts use the namespaced Claude invocation'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
