#!/usr/bin/env bash
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$REPO/plugins/skill-tools/skills/validate-dual-harness-skill/scripts/check-skill.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fixture NAME LINE... — writes a skill dir whose SKILL.md body is the given lines.
fixture() {
	local name="$1"; shift
	mkdir -p "$TMP/$name/skills/s"
	{ printf '%s\n' '---' 'name: s' 'description: d' '---'; printf '%s\n' "$@"; } >"$TMP/$name/skills/s/SKILL.md"
	printf '%s' "$TMP/$name"
}

accepts() { # label dir
	if bash "$CHECK" "$2" >"$TMP/out" 2>&1; then pass "$1"; else fail "$1"; sed 's/^/      /' "$TMP/out"; fi
}

rejects() { # label rule dir
	if bash "$CHECK" "$3" >"$TMP/out" 2>&1; then
		fail "$1 (exited 0)"
	elif grep -q "\[$2\]" "$TMP/out"; then
		pass "$1"
	else
		fail "$1 (no [$2] line)"; sed 's/^/      /' "$TMP/out"
	fi
}

accepts 'accepts exact CLAUDE_SKILL_DIR tokens' "$(fixture skill-ok 'bash ${CLAUDE_SKILL_DIR}/scripts/run.sh')"
accepts 'accepts exact CLAUDE_PLUGIN_ROOT tokens' "$(fixture plugin-ok 'node "${CLAUDE_PLUGIN_ROOT}/scripts/run.mjs"')"
rejects 'rejects skill-root traversal' path-traversal "$(fixture traversal 'bash "$SKILL_DIR/../../scripts/run.sh"')"
rejects 'rejects hardcoded Claude plugin-cache paths' path-cache "$(fixture cache 'bash ~/.claude/plugins/cache/example/run.sh')"
rejects 'rejects default-wrapped CLAUDE path tokens' path-default "$(fixture default 'SKILL_DIR="${CLAUDE_SKILL_DIR:-/x}"')"
accepts 'accepts exact tokens in dynamic context' "$(fixture dyn-ok '```!' 'bash "${CLAUDE_SKILL_DIR}/scripts/run.sh"' '```')"
rejects 'rejects placeholders in inline dynamic context' dynamic-placeholder \
	"$(fixture dyn-inline 'Docs: !`bash "<absolute skill directory>/scripts/run.sh"`')"
rejects 'rejects placeholders in fenced dynamic context' dynamic-placeholder \
	"$(fixture dyn-fenced '```!' 'bash "<plugin directory>/scripts/run.sh"' '```')"
rejects 'rejects Claude path tokens in Codex-only prose' codex-prose-token \
	"$(fixture codex-token 'Codex: run ${CLAUDE_SKILL_DIR}/scripts/run.sh yourself.')"
rejects 'rejects the argument token in Codex-only prose' codex-prose-arguments \
	"$(fixture codex-args 'Codex: read $ARGUMENTS from the request.')"

dir="$(fixture explicit-missing 'body')"
sed -i.bak 's/^description: d$/description: d\ndisable-model-invocation: true/' "$dir/skills/s/SKILL.md"
rejects 'rejects disable-model-invocation without a Codex policy mirror' explicit-only-parity "$dir"
mkdir -p "$dir/skills/s/agents"
printf '%s\n' 'policy:' '  allow_implicit_invocation: false' >"$dir/skills/s/agents/openai.yaml"
accepts 'accepts disable-model-invocation with a Codex policy mirror' "$dir"

dir="$(fixture body-mention 'disable-model-invocation: true appears only in the body here')"
accepts 'ignores disable-model-invocation outside frontmatter' "$dir"

mkdir -p "$TMP/standalone"
printf '%s\n' '---' 'name: s' '---' 'bash "$SKILL_DIR/../../x.sh"' >"$TMP/standalone/SKILL.md"
rejects 'scans a standalone skill dir not under skills/' path-traversal "$TMP/standalone"

dir="$(fixture excluded 'bash "$SKILL_DIR/../../x.sh"')"
if bash "$CHECK" --exclude '*/excluded/*' --exclude '*/other/*' "$dir" "$(fixture other-ok 'ok')" >"$TMP/out" 2>&1; then
	pass '--exclude skips matching files'
else
	fail '--exclude skips matching files'; sed 's/^/      /' "$TMP/out"
fi

bash "$CHECK" "$TMP/does-not-exist" >/dev/null 2>&1
[ $? -eq 2 ] && pass 'missing path is a usage error (exit 2)' || fail 'missing path is a usage error (exit 2)'

mkdir -p "$TMP/empty"
bash "$CHECK" "$TMP/empty" >/dev/null 2>&1
[ $? -eq 2 ] && pass 'no skill Markdown found is an error, not a clean pass' || fail 'no skill Markdown found is an error, not a clean pass'

if /bin/bash "$CHECK" "$(fixture bash32 'bash "$SKILL_DIR/../../x.sh"')" >/dev/null 2>&1; then
	fail 'runs under /bin/bash (macOS bash 3.2) and still reports'
else
	pass 'runs under /bin/bash (macOS bash 3.2) and still reports'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
