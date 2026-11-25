#!/usr/bin/env bash
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0
FAIL=0

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

CHECK="$REPO/plugins/skill-tools/skills/validate-dual-harness-skill/scripts/check-skill.sh"

# Rule fixtures live in plugins/skill-tools/tests/check-skill_test.sh; this suite
# applies the shared checker to the whole repo so the rules have one source.
if bash "$CHECK" --exclude '*/fable/*' "$REPO/plugins" >"$TMP_OUT" 2>&1; then
	pass 'plugin skill Markdown passes the dual-harness static checks'
else
	sed "s|$REPO/||; s/^/  /" "$TMP_OUT"
	fail 'plugin skill Markdown passes the dual-harness static checks'
fi

# Broader than check-skill.sh: READMEs and non-skill docs are model-read too.
codex_prose_violations=$(grep -RIlE '(Codex|Under Codex).*\$\{CLAUDE_(SKILL_DIR|PLUGIN_ROOT)\}' "$REPO/plugins" --include='*.md' | wc -l | tr -d ' ')
if [[ $codex_prose_violations -eq 0 ]]; then
	pass 'Codex fallback prose survives Claude path substitution'
else
	fail "Codex fallback prose contains Claude-substituted tokens ($codex_prose_violations files)"
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
