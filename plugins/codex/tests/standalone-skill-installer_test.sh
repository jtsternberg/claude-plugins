#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INSTALLER="$REPO/scripts/install-standalone-skill.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_installer() {
	bash "$INSTALLER" --skills-dir "$1" "${@:2}" >"$TMP/stdout" 2>"$TMP/stderr"
}

SYMLINK_SKILLS="$TMP/symlink-skills"
if run_installer "$SYMLINK_SKILLS" research-tools:fetch-docs \
	&& [ -L "$SYMLINK_SKILLS/fetch-docs" ] \
	&& [ "$(cd "$SYMLINK_SKILLS/fetch-docs" && pwd -P)" = "$REPO/plugins/research-tools/skills/fetch-docs" ]; then
	pass 'default install creates a symlink to the named skill'
else
	fail 'default install creates a symlink to the named skill'
fi

if bash "$SYMLINK_SKILLS/fetch-docs/scripts/fetch-docs.sh" --check >/dev/null 2>&1; then
	pass 'symlink install preserves and runs bundled scripts'
else
	fail 'symlink install preserves and runs bundled scripts'
fi

VERIFIED_STANDALONE_REFS=(
	beads-workflow:fix-findings-beads-tasks
	beads-workflow:tackle-epic
	git-commits:commit-staged
	git-commits:commit-unstaged
)
VERIFIED_STANDALONE_SKILLS="$TMP/verified-standalone-skills"
verified_standalone_ok=1
for skill_ref in "${VERIFIED_STANDALONE_REFS[@]}"; do
	if ! run_installer "$VERIFIED_STANDALONE_SKILLS" "$skill_ref"; then
		verified_standalone_ok=0
		break
	fi
done
if [ "$verified_standalone_ok" -eq 1 ] \
	&& [ -L "$VERIFIED_STANDALONE_SKILLS/fix-findings-beads-tasks" ] \
	&& [ -L "$VERIFIED_STANDALONE_SKILLS/tackle-epic" ] \
	&& [ -L "$VERIFIED_STANDALONE_SKILLS/commit-staged" ] \
	&& [ -L "$VERIFIED_STANDALONE_SKILLS/commit-unstaged" ]; then
	pass 'documented Beads and commit workflows install as standalone skills'
else
	fail 'documented Beads and commit workflows install as standalone skills'
fi

RELOCATED_REPO="$TMP/relocated-repo"
mkdir -p "$RELOCATED_REPO/scripts" "$RELOCATED_REPO/plugins/research-tools/skills"
cp "$INSTALLER" "$RELOCATED_REPO/scripts/install-standalone-skill.sh"
cp -R "$REPO/plugins/research-tools/skills/fetch-docs" "$RELOCATED_REPO/plugins/research-tools/skills/fetch-docs"
RELOCATED_SOURCE="$(cd "$RELOCATED_REPO/plugins/research-tools/skills/fetch-docs" && pwd -P)"
if bash "$RELOCATED_REPO/scripts/install-standalone-skill.sh" \
	--skills-dir "$SYMLINK_SKILLS" --force research-tools:fetch-docs >"$TMP/stdout" 2>"$TMP/stderr" \
	&& [ "$(readlink "$SYMLINK_SKILLS/fetch-docs")" = "$RELOCATED_SOURCE" ]; then
	pass '--force repairs a managed symlink after its source checkout moves'
else
	fail '--force repairs a managed symlink after its source checkout moves'
fi

COPY_SKILLS="$TMP/copy-skills"
if run_installer "$COPY_SKILLS" --copy research-tools:fetch-docs \
	&& [ -d "$COPY_SKILLS/fetch-docs" ] \
	&& [ ! -L "$COPY_SKILLS/fetch-docs" ] \
	&& bash "$COPY_SKILLS/fetch-docs/scripts/fetch-docs.sh" --check >/dev/null 2>&1; then
	pass 'copy install is self-contained and runs bundled scripts'
else
	fail 'copy install is self-contained and runs bundled scripts'
fi

MISSING_SKILLS="$TMP/missing-skills"
if ! run_installer "$MISSING_SKILLS" research-tools:not-a-skill \
	&& [ ! -e "$MISSING_SKILLS/not-a-skill" ]; then
	pass 'missing skills fail without creating a destination'
else
	fail 'missing skills fail without creating a destination'
fi

MALFORMED_REF_SKILLS="$TMP/malformed-ref-skills"
if ! run_installer "$MALFORMED_REF_SKILLS" fetch-docs \
	&& [ ! -e "$MALFORMED_REF_SKILLS/fetch-docs" ]; then
	pass 'skill references require an unambiguous plugin:skill name'
else
	fail 'skill references require an unambiguous plugin:skill name'
fi

UNKNOWN_FLAG_SKILLS="$TMP/unknown-flag-skills"
if ! bash "$INSTALLER" --skills-dir "$UNKNOWN_FLAG_SKILLS" --bogus research-tools:fetch-docs >"$TMP/stdout" 2>"$TMP/stderr" \
	&& [ ! -e "$UNKNOWN_FLAG_SKILLS" ]; then
	pass 'unknown flags are rejected before filesystem side effects'
else
	fail 'unknown flags are rejected before filesystem side effects'
fi

UNMANAGED_SKILLS="$TMP/unmanaged-skills"
mkdir -p "$UNMANAGED_SKILLS/fetch-docs"
printf 'keep\n' >"$UNMANAGED_SKILLS/fetch-docs/keep.txt"
if ! run_installer "$UNMANAGED_SKILLS" research-tools:fetch-docs \
	&& [ "$(sed -n '1p' "$UNMANAGED_SKILLS/fetch-docs/keep.txt")" = keep ]; then
	pass 'existing destinations are preserved without --force'
else
	fail 'existing destinations are preserved without --force'
fi

printf 'changed locally\n' >"$COPY_SKILLS/fetch-docs/SKILL.md"
if ! run_installer "$COPY_SKILLS" --copy research-tools:fetch-docs \
	&& [ "$(sed -n '1p' "$COPY_SKILLS/fetch-docs/SKILL.md")" = 'changed locally' ]; then
	pass 'copy updates require explicit --force'
else
	fail 'copy updates require explicit --force'
fi

if run_installer "$COPY_SKILLS" --copy --force research-tools:fetch-docs \
	&& grep -q '^name: fetch-docs$' "$COPY_SKILLS/fetch-docs/SKILL.md"; then
	pass '--force refreshes a managed copied skill from source'
else
	fail '--force refreshes a managed copied skill from source'
fi

if run_installer "$COPY_SKILLS" --uninstall research-tools:fetch-docs \
	&& [ ! -e "$COPY_SKILLS/fetch-docs" ]; then
	pass 'uninstall removes a managed standalone skill'
else
	fail 'uninstall removes a managed standalone skill'
fi

if ! run_installer "$UNMANAGED_SKILLS" --uninstall research-tools:fetch-docs \
	&& [ -f "$UNMANAGED_SKILLS/fetch-docs/keep.txt" ]; then
	pass 'uninstall refuses to remove an unmanaged destination'
else
	fail 'uninstall refuses to remove an unmanaged destination'
fi

SHARED_SKILLS="$TMP/shared-skills"
if ! run_installer "$SHARED_SKILLS" session-tools:sessions-catch-up \
	&& [ ! -e "$SHARED_SKILLS/sessions-catch-up" ]; then
	pass 'skills that depend on plugin-root resources are rejected'
else
	fail 'skills that depend on plugin-root resources are rejected'
fi

FIXTURE_REPO="$TMP/malformed-repo"
mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/plugins/demo/skills/broken"
cp "$INSTALLER" "$FIXTURE_REPO/scripts/install-standalone-skill.sh" 2>/dev/null || true
printf '%s\n' '---' 'name: broken' '---' >"$FIXTURE_REPO/plugins/demo/skills/broken/SKILL.md"
FIXTURE_SKILLS="$TMP/fixture-skills"
if ! bash "$FIXTURE_REPO/scripts/install-standalone-skill.sh" --skills-dir "$FIXTURE_SKILLS" demo:broken >"$TMP/stdout" 2>"$TMP/stderr" \
	&& [ ! -e "$FIXTURE_SKILLS/broken" ]; then
	pass 'malformed skill layouts fail before installation'
else
	fail 'malformed skill layouts fail before installation'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
