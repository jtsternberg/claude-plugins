#!/usr/bin/env bash
set -euo pipefail

print_help() {
	cat <<'EOF'
Usage: install-standalone-skill.sh [options] <plugin>:<skill>

Install one self-contained skill from this repository for Codex.

Options:
  --copy               Copy the skill instead of creating a symlink.
  --force              Replace an existing install managed by this script.
  --uninstall          Remove an install managed by this script.
  --skills-dir PATH    Override the destination (default: $HOME/.agents/skills).
  -h, --help           Show this help.

Examples:
  bash scripts/install-standalone-skill.sh research-tools:fetch-docs
  bash scripts/install-standalone-skill.sh --copy research-tools:fetch-docs
  bash scripts/install-standalone-skill.sh --copy --force research-tools:fetch-docs
  bash scripts/install-standalone-skill.sh --uninstall research-tools:fetch-docs
EOF
}

die() {
	printf 'install-standalone-skill: %s\n' "$*" >&2
	exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
skills_dir="${HOME}/.agents/skills"
mode=symlink
force=0
uninstall=0
skill_ref=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--copy)
			mode=copy
			shift
			;;
		--force)
			force=1
			shift
			;;
		--uninstall)
			uninstall=1
			shift
			;;
		--skills-dir)
			[ "$#" -ge 2 ] || die '--skills-dir requires a path'
			skills_dir="$2"
			shift 2
			;;
		-h|--help)
			print_help
			exit 0
			;;
		--*)
			die "unknown flag: $1"
			;;
		*)
			[ -z "$skill_ref" ] || die "unexpected positional argument: $1"
			skill_ref="$1"
			shift
			;;
	esac
done

[ -n "$skill_ref" ] || die 'a plugin:skill name is required'
[[ "$skill_ref" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$ ]] \
	|| die "invalid skill name '$skill_ref'; expected plugin:skill"
[ -n "$skills_dir" ] || die '--skills-dir cannot be empty'
[ "$skills_dir" != / ] || die '--skills-dir cannot be /'
[ "$uninstall" -eq 0 ] || [ "$mode" = symlink ] || die '--copy cannot be combined with --uninstall'
[ "$uninstall" -eq 0 ] || [ "$force" -eq 0 ] || die '--force cannot be combined with --uninstall'

plugin="${skill_ref%%:*}"
skill="${skill_ref#*:}"
source_dir="$repo_root/plugins/$plugin/skills/$skill"
# Plugins in a group dir live one level deeper (plugins/<group>/<plugin>/skills/<skill>).
if [ ! -d "$source_dir" ]; then
	for candidate in "$repo_root"/plugins/*/"$plugin"/skills/"$skill"; do
		[ -d "$candidate" ] && source_dir="$candidate" && break
	done
fi
dest="$skills_dir/$skill"
marker="$dest/.claude-plugins-standalone"

destination_exists() {
	[ -e "$dest" ] || [ -L "$dest" ]
}

is_managed_destination() {
	if [ -L "$dest" ]; then
		symlink_target="$(readlink "$dest")"
		case "$symlink_target" in
			*/plugins/"$plugin"/skills/"$skill") return 0 ;;
			*) return 1 ;;
		esac
	fi
	[ -f "$marker" ] && [ "$(sed -n '1p' "$marker")" = "$skill_ref" ]
}

remove_destination() {
	case "$dest" in
		"$skills_dir"/"$skill") ;;
		*) die 'refusing to remove a destination outside the selected skills directory' ;;
	esac
	if [ -L "$dest" ]; then
		rm -f -- "$dest"
	else
		rm -rf -- "$dest"
	fi
}

if [ "$uninstall" -eq 1 ]; then
	destination_exists || die "$skill_ref is not installed at $dest"
	is_managed_destination \
		|| die "refusing to uninstall unmanaged destination: $dest"
	remove_destination
	printf 'Uninstalled %s from %s\n' "$skill_ref" "$dest"
	exit 0
fi

[ -d "$source_dir" ] || die "skill not found: $skill_ref"
[ -f "$source_dir/SKILL.md" ] || die "skill has no SKILL.md: $skill_ref"

frontmatter_name="$(awk '
	NR == 1 && $0 == "---" { in_frontmatter = 1; next }
	in_frontmatter && $0 == "---" { exit }
	in_frontmatter && /^name:[[:space:]]*/ {
		sub(/^name:[[:space:]]*/, "")
		gsub(/^["'\'' ]+|["'\'' ]+$/, "")
		print
		exit
	}
' "$source_dir/SKILL.md")"
frontmatter_description="$(awk '
	NR == 1 && $0 == "---" { in_frontmatter = 1; next }
	in_frontmatter && $0 == "---" { exit }
	in_frontmatter && /^description:[[:space:]]*[^|>[:space:]]/ { print "yes"; exit }
	in_frontmatter && /^description:[[:space:]]*[|>][[:space:]]*$/ { print "yes"; exit }
' "$source_dir/SKILL.md")"

[ "$frontmatter_name" = "$skill" ] \
	|| die "SKILL.md name must be '$skill' for $skill_ref"
[ "$frontmatter_description" = yes ] \
	|| die "SKILL.md must declare a non-empty description for $skill_ref"

# The token is intentionally literal: expansion would hide the dependency.
# shellcheck disable=SC2016
if grep -RqsF --include='*.md' '${CLAUDE_PLUGIN_ROOT}' "$source_dir"; then
	die "$skill_ref depends on plugin-root resources and cannot be installed standalone"
fi

if destination_exists; then
	[ "$force" -eq 1 ] || die "destination already exists: $dest (use --force to refresh a managed install)"
	is_managed_destination \
		|| die "refusing to replace unmanaged destination: $dest"
fi

mkdir -p "$skills_dir"
tmp_path="$(mktemp -d "$skills_dir/.${skill}.tmp.XXXXXX")"
rmdir "$tmp_path"
cleanup() {
	if [ -L "$tmp_path" ]; then
		rm -f -- "$tmp_path"
	elif [ -e "$tmp_path" ]; then
		rm -rf -- "$tmp_path"
	fi
}
trap cleanup EXIT

if [ "$mode" = copy ]; then
	cp -R "$source_dir" "$tmp_path"
	printf '%s\n' "$skill_ref" >"$tmp_path/.claude-plugins-standalone"
else
	ln -s "$source_dir" "$tmp_path"
fi

if destination_exists; then
	remove_destination
fi
mv "$tmp_path" "$dest"
trap - EXIT

if [ "$mode" = copy ]; then
	printf 'Copied %s to %s\n' "$skill_ref" "$dest"
else
	printf 'Linked %s to %s\n' "$skill_ref" "$dest"
fi
