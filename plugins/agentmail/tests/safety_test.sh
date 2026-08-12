#!/usr/bin/env bash
# =============================================================================
# The rules that actually cost something if a later edit gets them wrong.
#
# Three hazards, all of them one careless edit away:
#   1. Auto-installing software without consent (global npm state is machine-wide).
#   2. Leaking a live API key into the transcript (archived AND locally indexed).
#   3. Broadening allowed-tools so sending email stops prompting — email cannot
#      be recalled, and this CLI exposes no idempotency key to make a retry safe.
#
# Each is asserted here rather than trusted to prose, because prose is advisory
# and a test is not.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PLUGIN_ROOT" || exit 1

SKILL="skills/using-agentmail/SKILL.md"
SCRIPTS="skills/using-agentmail/scripts"

# Enumerate by GLOB, never by a hardcoded list. The preflight moved from a skill's
# scripts/ to the plugin root and a hardcoded list silently stopped covering it —
# the suite still reported all-green with two fewer assertions, which is exactly
# how a security check rots. Same reason tests/run-all.sh discovers suites by glob.
ALL_SH=()
while IFS= read -r f; do ALL_SH+=("$f"); done < <(
	find scripts skills/*/scripts hooks/scripts -name '*.sh' -type f 2>/dev/null | sort
)

ALL_SKILLS=()
while IFS= read -r f; do ALL_SKILLS+=("$f"); done < <(
	find skills -mindepth 2 -maxdepth 2 -name 'SKILL.md' -type f 2>/dev/null | sort
)

ALL_DOCS=("${ALL_SKILLS[@]}")
while IFS= read -r f; do ALL_DOCS+=("$f"); done < <(
	find references skills/*/references -name '*.md' -type f 2>/dev/null | sort
)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

# Executable lines only. Three things in these files legitimately CONTAIN the
# forms these checks ban, and all three must be stripped or every check is a
# false positive:
#   - comments (they explain why a form is banned)
#   - heredoc bodies (the preflight PRINTS the npm install command as advice; it
#     does not run it — the whole point is that the user runs it)
#   - blank lines
exec_lines() {   # exec_lines <file>
	awk '
		# Entering a heredoc: remember the terminator, skip until we see it.
		!inheredoc && /<<-?[[:space:]]*'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/ {
			line = $0
			sub(/^.*<<-?[[:space:]]*/, "", line)
			gsub(/'"'"'|"/, "", line)
			sub(/[[:space:]].*$/, "", line)
			if (line != "") { term = line; inheredoc = 1; next }
		}
		inheredoc {
			stripped = $0
			sub(/^[[:space:]]*/, "", stripped)
			if (stripped == term) { inheredoc = 0 }
			next
		}
		{ print NR ": " $0 }
	' "$1" 2>/dev/null | grep -vE '^[0-9]+: *#' | grep -vE '^[0-9]+: *$'
}

# Markdown prose wraps, so a multi-word phrase can straddle a line break and
# defeat a naive grep. Flatten whitespace before matching a phrase.
has_phrase() {   # has_phrase <file> <phrase>
	tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiF -- "$2"
}

# Fenced bash blocks in markdown — the only part of a doc that is a command the
# model might copy. Prose that names a command in order to forbid it is not.
md_bash_blocks() {   # md_bash_blocks <file>
	awk '/^```(bash|sh)$/{f=1;next} /^```/{f=0} f' "$1" 2>/dev/null
}

echo "== 1. no installer runs without consent =="

install_hits=""
for f in "${ALL_SH[@]}"; do
	[ -f "$f" ] || continue
	hits="$(exec_lines "$f" | grep -nE '(npm[[:space:]]+(install|i)[[:space:]]|brew[[:space:]]+install|curl[^|]*\|[[:space:]]*(ba)?sh|gh[[:space:]]+release[[:space:]]+download)' || true)"
	[ -n "$hits" ] && install_hits="$install_hits$f: $hits"$'\n'
done
if [ -z "$install_hits" ]; then
	ok "no script executes an installer"
else
	bad "a script executes an installer" "$install_hits"
fi

# The skill must still TELL the user how to install — refusing to run it is not
# the same as hiding it.
if grep -q 'npm install -g agentmail-cli' "$SKILL"; then
	ok "SKILL.md documents the install command for the user to run"
else
	bad "SKILL.md does not document how to install the CLI"
fi
if has_phrase "$SKILL" "without explicit user consent"; then
	ok "SKILL.md states the consent rule"
else
	bad "SKILL.md does not state the never-install-without-consent rule"
fi

echo
echo "== 2. no credential reaches stdout or an unsafe file =="

# sign-up must never run without capturing stdout: a bare invocation writes the
# API key straight into the transcript. Scope: executable shell only, plus fenced
# bash blocks in the docs (a command the model might copy). Prose that names the
# command in order to FORBID it is not a violation — the docs do exactly that.
bare_signup=""
for f in "${ALL_SH[@]}"; do
	[ -f "$f" ] || continue
	hits="$(exec_lines "$f" | grep -E 'agentmail[[:space:]]+agent[[:space:]]+sign-up' | grep -vE '\$\(|=\$' || true)"
	[ -n "$hits" ] && bare_signup="$bare_signup$f: $hits"$'\n'
done
for f in "${ALL_DOCS[@]}"; do
	[ -f "$f" ] || continue
	hits="$(md_bash_blocks "$f" | grep -nE 'agentmail[[:space:]]+agent[[:space:]]+sign-up' | grep -vE '\$\(|=\$|^[[:space:]]*#' || true)"
	[ -n "$hits" ] && bare_signup="$bare_signup$f (bash block): $hits"$'\n'
done
if [ -z "$bare_signup" ]; then
	ok "no executable line or doc bash block runs 'agent sign-up' uncaptured"
else
	bad "'agent sign-up' runs uncaptured — its API key would land in the transcript" "$bare_signup"
fi

# And the docs must actively forbid it, not merely avoid it.
if has_phrase "$SKILL" "never run \`agentmail agent sign-up\` directly"; then
	ok "SKILL.md explicitly forbids running 'agent sign-up' directly"
else
	bad "SKILL.md does not explicitly forbid running 'agent sign-up' directly"
fi

# Anything printing a key-shaped variable must mask it.
leak_hits=""
for f in "${ALL_SH[@]}"; do
	[ -f "$f" ] || continue
	hits="$(exec_lines "$f" | grep -nE '(echo|printf)[^#]*\$\{?(AGENTMAIL_)?API_KEY|(echo|printf)[^#]*\$\{?KEY\}?[[:space:]]*$' | grep -v 'mask' || true)"
	[ -n "$hits" ] && leak_hits="$leak_hits$f: $hits"$'\n'
done
if [ -z "$leak_hits" ]; then
	ok "no script prints a key variable unmasked"
else
	bad "a script prints a key variable without masking" "$leak_hits"
fi

# Every script that writes a credential must tighten permissions.
for f in "$SCRIPTS"/agentmail-signup.sh "$SCRIPTS"/agentmail-verify.sh; do
	[ -f "$f" ] || continue
	if grep -q 'umask 077' "$f" && grep -q 'chmod 600' "$f"; then
		ok "$(basename "$f") sets umask 077 and chmod 600 on credential files"
	else
		bad "$(basename "$f") writes credentials without both umask 077 and chmod 600"
	fi
done

# A project .env is exactly the wrong place for this — it gets committed.
env_hits=""
for f in "${ALL_SH[@]}"; do
	[ -f "$f" ] || continue
	hits="$(exec_lines "$f" | grep -nE '>[[:space:]]*[^[:space:]]*\.env' || true)"
	[ -n "$hits" ] && env_hits="$env_hits$f: $hits"$'\n'
done
if [ -z "$env_hits" ]; then
	ok "no script writes to a .env file"
else
	bad "a script writes to a .env file" "$env_hits"
fi

# No key-shaped literal anywhere in the plugin. Test fixtures need a key-shaped
# value, so an obviously-labelled fake (STUB/FAKE/EXAMPLE/PLACEHOLDER in the
# literal itself) is allowed — the check still catches an unlabelled one, which
# is what a real leak looks like.
key_literals="$(grep -rInE 'am_(us|eu)?_[A-Za-z0-9]{16,}' . 2>/dev/null \
	| grep -viE 'am_(us|eu)?_[A-Za-z0-9]*(STUB|FAKE|EXAMPLE|PLACEHOLDER|xxx)' || true)"
if [ -z "$key_literals" ]; then
	ok "no unlabelled key-shaped literal committed anywhere in the plugin"
else
	bad "something that looks like a real API key is committed" "$key_literals"
fi

# The model must be told not to read the credential file back into context.
if grep -qiE 'do not .{0,20}(`?Read`?|read) that file|not to `Read` that file' "$SKILL" \
   || grep -qiE 'do not `?Read`? that file' skills/using-agentmail/references/onboarding.md; then
	ok "docs tell the model not to Read the credential file into the conversation"
else
	bad "docs never tell the model to keep the credential file out of context"
fi

echo
echo "== 3. sending stays behind a permission prompt =="

allowed="$(sed -n '/^allowed-tools:/,/^---$/p' "$SKILL")"

# The core assertion. If any of these verbs is allowlisted, sending or deleting
# email stops prompting, and the harness-level guard on an irreversible,
# outward-facing action is gone.
dangerous=""
for verb in send reply reply-all forward delete "inboxes create" "inboxes update" \
            "drafts create" "drafts update" "messages update" sign-up verify \
            "api-keys" domains webhooks lists pods; do
	printf '%s' "$allowed" | grep -qF -- "$verb" && dangerous="$dangerous $verb"
done
if [ -z "$dangerous" ]; then
	ok "allowed-tools contains no sending, creating, updating, or deleting verb"
else
	bad "allowed-tools grants a mutating verb:$dangerous" \
	    "These must fall through to a permission prompt. Do not broaden to Bash(agentmail *)."
fi

# The blanket grant is the specific failure mode to prevent.
if printf '%s' "$allowed" | grep -qE '"Bash\(agentmail \*\)"'; then
	bad "allowed-tools contains the blanket Bash(agentmail *) grant" \
	    "That silently allows every send and every delete."
else
	ok "no blanket Bash(agentmail *) grant"
fi

# The prose gate, which does the part a permission prompt cannot: show the user
# the actual recipients and body.
if has_phrase "$SKILL" "get explicit confirmation"; then
	ok "SKILL.md requires explicit confirmation before a send"
else
	bad "SKILL.md has no explicit pre-send confirmation rule"
fi
if has_phrase "$SKILL" "one confirmation covers one send, not a session"; then
	ok "SKILL.md scopes confirmation to a single send"
else
	bad "SKILL.md does not scope confirmation per-send (a session-wide OK is not consent)"
fi
if grep -qiE 'the prompt is the feature|Do not "fix" this by broadening' "$SKILL"; then
	ok "SKILL.md explains why sends are off the allowlist (so nobody 'fixes' it)"
else
	bad "SKILL.md does not explain the deliberate allowlist omission"
fi

echo
echo "== 4. no retry loop around an irreversible send =="

# There is no --idempotency-key on any send command, so a retry can deliver a
# second real email. The skill must say so and must not suggest otherwise.
if grep -qiE 'never retry a failed send' "$SKILL"; then
	ok "SKILL.md carries the never-retry-a-send rule"
else
	bad "SKILL.md does not tell the model never to retry a send"
fi

if grep -qiE 'inboxes:messages list' "$SKILL" && grep -qiE 'whether it actually went out|did it actually go out' "$SKILL" 2>/dev/null; then
	ok "SKILL.md gives the verify-instead-of-retry procedure"
else
	bad "SKILL.md does not say how to check whether an ambiguous send landed"
fi

# The distinction the work order got wrong: client_id covers creates, not sends.
if grep -q 'client_id` does not cover sends' "$SKILL" || grep -qi 'does not cover sends' "$SKILL"; then
	ok "SKILL.md distinguishes client_id (creates) from Idempotency-Key (sends)"
else
	bad "SKILL.md does not distinguish create-idempotency from send-idempotency"
fi

# A literal retry loop wrapped around a send would defeat all of the above.
retry_hits=""
for f in "${ALL_DOCS[@]}"; do
	[ -f "$f" ] || continue
	hits="$(grep -nE '(for|while).*(retry|attempt).*(send)|send.*\|\|.*(send|retry)' "$f" || true)"
	[ -n "$hits" ] && retry_hits="$retry_hits$f: $hits"$'\n'
done
if [ -z "$retry_hits" ]; then
	ok "no retry loop wrapped around a send in any doc"
else
	bad "a doc shows a retry loop around a send" "$retry_hits"
fi

echo
echo "== 5. scripts are runnable and honest =="

for f in "${ALL_SH[@]}" "$SCRIPT_DIR"/*_test.sh; do
	[ -f "$f" ] || continue
	bash -n "$f" 2>/dev/null && ok "$(basename "$f") parses" || bad "$(basename "$f") has a syntax error"
done

for f in "${ALL_SH[@]}"; do
	[ -f "$f" ] || continue
	[ -x "$f" ] && ok "$(basename "$f") is executable" || bad "$(basename "$f") is not executable"
done

# Merging stderr into a parser's stdin is a mistake this repo has already paid
# for once (gws auth_check_drift). Don't re-grow it here.
merge_hits=""
for f in "${ALL_SH[@]}"; do
	[ -f "$f" ] || continue
	hits="$(exec_lines "$f" | grep -nE 'agentmail[^#]*2>&1[[:space:]]*\|' || true)"
	[ -n "$hits" ] && merge_hits="$merge_hits$f: $hits"$'\n'
done
if [ -z "$merge_hits" ]; then
	ok "no script pipes merged agentmail stdout+stderr into a parser"
else
	bad "a script merges agentmail stderr into a parser's stdin" "$merge_hits"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
