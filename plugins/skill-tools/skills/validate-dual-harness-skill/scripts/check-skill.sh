#!/usr/bin/env bash
# Static Claude Code / Codex portability checks for skill Markdown.
# Usage: check-skill.sh [--exclude GLOB]... PATH...
#   PATH: a SKILL.md or other .md file, a skill dir, a plugin dir, or a repo root.
#   --exclude GLOB: skip files whose path matches the shell glob (repeatable).
# Exit: 0 clean, 1 violations found, 2 usage error.
# Must stay bash-3.2 compatible (macOS /bin/bash): no mapfile, no assoc arrays.
set -u

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

EXCLUDES=()
TARGETS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--exclude) [ $# -ge 2 ] || usage; EXCLUDES+=("$2"); shift 2 ;;
		-h|--help) usage ;;
		*) TARGETS+=("$1"); shift ;;
	esac
done
[ ${#TARGETS[@]} -gt 0 ] || usage

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT

for target in "${TARGETS[@]}"; do
	if [ -f "$target" ]; then
		printf '%s\n' "$target" >>"$LIST"
	elif [ -d "$target" ]; then
		target="${target%/}"
		# A bare skill dir (standalone skill not under skills/) is in scope as a whole.
		if [ -f "$target/SKILL.md" ]; then
			find "$target" -type f -name '*.md' ! -name README.md -print >>"$LIST"
		else
			find "$target" -type f -name '*.md' ! -name README.md \
				\( -path '*/skills/*' -o -path '*/references/*' \) \
				! -path '*/node_modules/*' ! -path '*/.git/*' -print >>"$LIST"
		fi
	else
		printf 'check-skill: no such file or directory: %s\n' "$target" >&2
		exit 2
	fi
done

VIOLATIONS=0
CHECKED=0

report() { # file line rule message
	printf '%s:%s: [%s] %s\n' "$1" "$2" "$3" "$4"
	VIOLATIONS=$((VIOLATIONS + 1))
}

grep_rule() { # file rule message regex
	local hit
	while IFS= read -r hit; do
		[ -n "$hit" ] && report "$1" "${hit%%:*}" "$2" "$3"
	done <<EOF
$(grep -nE "$4" "$1" 2>/dev/null)
EOF
}

excluded() {
	local pat
	for pat in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
		# shellcheck disable=SC2254
		case "$1" in $pat) return 0 ;; esac
	done
	return 1
}

frontmatter_has() { # file regex — true when the YAML frontmatter matches
	awk -v re="$2" '
		NR == 1 && $0 != "---" { exit 1 }
		NR > 1 && $0 == "---" { exit found ? 0 : 1 }
		NR > 1 && $0 ~ re { found = 1 }
		END { if (NR < 2) exit 1 }
	' "$1"
}

while IFS= read -r file; do
	[ -n "$file" ] || continue
	excluded "$file" && continue
	CHECKED=$((CHECKED + 1))

	grep_rule "$file" path-default \
		'default-wrapped CLAUDE path token; Claude resolves only the bare form — put Codex guidance in adjacent prose' \
		'\$\{CLAUDE_(SKILL_DIR|PLUGIN_ROOT):-'
	grep_rule "$file" path-traversal \
		'traversal out of the skill dir; keep shared resources at the plugin root and use CLAUDE_PLUGIN_ROOT' \
		'\$\{CLAUDE_SKILL_DIR[^}]*\}/\.\./\.\.|\$(SKILL_DIR|PLUGIN_ROOT)/\.\./\.\.'
	grep_rule "$file" path-cache \
		'hardcoded Claude plugin-cache path; it breaks on reinstall and does not exist under Codex' \
		'(\$HOME|~)/\.claude/plugins/'
	grep_rule "$file" codex-prose-token \
		'Codex-only prose contains a Claude path token, which Claude substitutes before Codex ever sees it' \
		'(Codex|Under Codex).*\$\{CLAUDE_(SKILL_DIR|PLUGIN_ROOT)\}'

	case "$file" in
		*SKILL.md) ;;
		*) continue ;;
	esac

	grep_rule "$file" codex-prose-arguments \
		'Codex-only prose contains the Claude argument token, which Claude substitutes in place' \
		'Codex.*\$ARGUMENTS'

	while IFS= read -r line; do
		[ -n "$line" ] && report "$file" "$line" dynamic-placeholder \
			'dynamic (!) context runs before the model reads the prompt; it needs a mechanically resolvable path, not a default or <placeholder>'
	done <<EOF
$(awk '
	/^[[:space:]]*```!/ { fenced = 1; next }
	fenced && /^[[:space:]]*```[[:space:]]*$/ { fenced = 0; next }
	{
		dynamic = fenced || index($0, "!`") > 0
		if (dynamic && ($0 ~ /\$\{CLAUDE_[^}]*:-/ || $0 ~ /<[^>]*(path|directory)[^>]*>/)) print NR
	}
' "$file")
EOF

	if frontmatter_has "$file" '^disable-model-invocation:[[:space:]]*true[[:space:]]*$'; then
		yaml="$(dirname "$file")/agents/openai.yaml"
		if ! grep -Eq '^[[:space:]]*allow_implicit_invocation:[[:space:]]*false' "$yaml" 2>/dev/null; then
			report "$file" 1 explicit-only-parity \
				"disable-model-invocation: true has no Codex mirror; add policy.allow_implicit_invocation: false to $(dirname "$file")/agents/openai.yaml"
		fi
	fi
done <"$LIST"

if [ "$CHECKED" -eq 0 ]; then
	printf 'check-skill: no skill Markdown found under: %s\n' "${TARGETS[*]}" >&2
	exit 2
fi
printf 'check-skill: %d files checked, %d violations\n' "$CHECKED" "$VIOLATIONS"
[ "$VIOLATIONS" -eq 0 ]
