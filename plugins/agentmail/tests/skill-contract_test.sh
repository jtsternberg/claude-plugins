#!/usr/bin/env bash
# =============================================================================
# Dual-harness contract checks for every agentmail skill.
#
# Enforces AGENTS.md § Dual-Harness Skill Contract mechanically, so a later edit
# that reads fine under Claude Code but silently breaks Codex fails here instead
# of in someone's session.
#
# Skills are discovered by GLOB. A hardcoded list is how a fifth skill ships with
# none of these guarantees while the suite still reports all-green.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PLUGIN_ROOT" || exit 1

HUB="skills/using-agentmail/SKILL.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

SKILLS=()
while IFS= read -r d; do SKILLS+=("$d"); done < <(
	find skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
)

# Every skill's description must carry its own Codex routing terms — Codex
# ignores when_to_use entirely, so a term that lives only there is invisible to it.
routing_terms() {
	case "$1" in
		using-agentmail)  echo "email inbox send reply forward draft AgentMail" ;;
		contacts)         echo "contact address email name AgentMail" ;;
		check-mail)       echo "unread inbox mail read triage AgentMail" ;;
		replying)         echo "reply forward draft thread email AgentMail" ;;
		relay-work-order) echo "agent handoff email work AgentMail" ;;
		*)                echo "AgentMail email" ;;
	esac
}

echo "== discovery =="

if [ "${#SKILLS[@]}" -eq 0 ]; then
	bad "no skills found under skills/"
	echo "0 passed, 1 failed"; exit 1
fi
ok "found ${#SKILLS[@]} skill director$( [ "${#SKILLS[@]}" -eq 1 ] && echo y || echo ies )"

for f in .claude-plugin/plugin.json hooks/hooks.json; do
	[ -f "$f" ] && ok "$f exists" || bad "$f missing"
done

# plugin.json must parse and name itself consistently with its directory.
if python3 -c "
import json,sys
d=json.load(open('.claude-plugin/plugin.json'))
assert d['name']=='agentmail', d['name']
assert d['version'], 'no version'
assert len(d['description'])>80, 'description too thin for Codex routing'
" 2>/dev/null; then
	ok "plugin.json parses, name matches directory, description is substantive"
else
	bad "plugin.json invalid, misnamed, or description too thin"
fi

for d in "${SKILLS[@]}"; do
	name="$(basename "$d")"
	if [ -f "$d/SKILL.md" ]; then
		ok "$name: SKILL.md is at the discoverable path"
	else
		bad "$name: no SKILL.md at $d/SKILL.md (autocomplete depends on this path)"
	fi
	if [ -f "$d/agents/openai.yaml" ]; then
		ok "$name: agents/openai.yaml exists"
	else
		bad "$name: agents/openai.yaml missing (Codex presentation parity)"
	fi
done

echo
echo "== frontmatter =="

frontmatter() { sed -n '2,/^---$/p' "$1"; }

for d in "${SKILLS[@]}"; do
	name="$(basename "$d")"
	skill="$d/SKILL.md"
	[ -f "$skill" ] || continue

	miss=""
	for key in name description when_to_use argument-hint allowed-tools; do
		frontmatter "$skill" | grep -q "^${key}:" || miss="$miss $key"
	done
	[ -z "$miss" ] && ok "$name: frontmatter has every required key" \
		|| bad "$name: frontmatter missing:$miss"

	if frontmatter "$skill" | grep -q "^name: ${name}\$"; then
		ok "$name: frontmatter name matches the directory (invocation path depends on it)"
	else
		bad "$name: frontmatter name does not match its directory" \
			"$(frontmatter "$skill" | sed -n 's/^name: *//p')"
	fi

	desc="$(frontmatter "$skill" | sed -n 's/^description: *//p')"
	missing_terms=""
	for term in $(routing_terms "$name"); do
		printf '%s' "$desc" | grep -qi -- "$term" || missing_terms="$missing_terms $term"
	done
	[ -z "$missing_terms" ] && ok "$name: description carries its Codex routing terms" \
		|| bad "$name: description missing Codex routing terms:$missing_terms" \
		       "Codex does not read when_to_use — these must be in description."
done

echo
echo "== path tokens =="

# Every markdown file in the plugin that can carry a path token.
DOCS=()
while IFS= read -r f; do DOCS+=("$f"); done < <(
	find skills references -name '*.md' -type f 2>/dev/null | sort
)

for f in "${DOCS[@]}"; do
	base="$(echo "$f" | sed 's#^skills/##; s#/SKILL.md$##')"

	# Bare token only. A shell-default wrapper stops Claude Code resolving it.
	if grep -qE 'CLAUDE_(SKILL_DIR|PLUGIN_ROOT):-' "$f"; then
		bad "$base: a path token is wrapped in a shell default (\${...:-...})" \
			"Claude Code resolves the bare token mechanically; a wrapper defeats it."
	fi

	# The skill token names the skill's own directory; traversing out of it is
	# unsupported. CLAUDE_PLUGIN_ROOT is the supported way to reach shared files.
	if grep -q 'CLAUDE_SKILL_DIR}/\.\.' "$f"; then
		bad "$base: traversal out of the skill directory (\${CLAUDE_SKILL_DIR}/../)"
	fi
done
ok "no shell-default wrapper around any path token"
ok "no traversal out of a skill directory"

# Every file that USES a path variable must also ASSIGN it — Codex shells keep no
# state between independently executed blocks.
for f in "${DOCS[@]}"; do
	base="$(echo "$f" | sed 's#^skills/##; s#/SKILL.md$##')"
	for var in SKILL_DIR PLUGIN_ROOT; do
		token="CLAUDE_${var}"
		uses=$(grep -c "\"\$${var}" "$f" 2>/dev/null || true)
		assigns=$(grep -c "^${var}=\"\\\${${token}}\"\$" "$f" 2>/dev/null || true)
		if [ "${uses:-0}" -eq 0 ]; then
			continue
		fi
		if [ "${assigns:-0}" -ge 1 ]; then
			ok "$base: \$$var used $uses time(s), assigned $assigns time(s)"
		else
			bad "$base uses \$$var but never assigns it from \${$token}"
		fi
	done
done

# Every assignment needs an adjacent Codex substitution instruction, and that
# instruction must NOT itself contain the token (Codex would copy it verbatim).
for f in "${DOCS[@]}"; do
	base="$(echo "$f" | sed 's#^skills/##; s#/SKILL.md$##')"
	for var in SKILL_DIR PLUGIN_ROOT; do
		token="CLAUDE_${var}"
		lines=$(grep -n "^${var}=\"\\\${${token}}\"\$" "$f" | cut -d: -f1)
		[ -n "$lines" ] || continue
		codex_ok=1
		for ln in $lines; do
			prev=$((ln - 1))
			line="$(sed -n "${prev}p" "$f")"
			printf '%s' "$line" | grep -qi 'codex' || codex_ok=0
			printf '%s' "$line" | grep -q "$token" && codex_ok=0
		done
		[ "$codex_ok" -eq 1 ] \
			&& ok "$base: every $var assignment has an adjacent Codex note that omits the token" \
			|| bad "$base: a $var assignment lacks an adjacent Codex note, or the note repeats the token"
	done
done

echo
echo "== dynamic context (! blocks) =="

# A compound operator in a ! block trips Claude Code's shell-operator permission
# gate at load time. Multiple LINES are fine; operators are not. Comment lines are
# stripped first: a Codex substitution note contains a semicolon as ordinary
# English punctuation, and a comment cannot trip a shell gate.
bang_bodies="$(awk '/^```!$/{f=1;next} /^```$/{f=0} f' "$HUB")"
bang_exec="$(printf '%s\n' "$bang_bodies" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$')"
if [ -z "$bang_bodies" ]; then
	bad "the hub skill has no ! block — it should inject live preflight context"
else
	ok "hub ! block present"
	if printf '%s' "$bang_exec" | grep -qE '&&|\|\||[^|]\|[^|]|;'; then
		bad "a ! block has a compound shell operator on an executable line (&&, ||, |, ;)" \
			"$(printf '%s' "$bang_exec" | grep -nE '&&|\|\||[^|]\|[^|]|;' | head -3)"
	else
		ok "no compound shell operator on any executable ! block line"
	fi
fi

bang_count="$(grep -c '^```!$' "$HUB")"
if [ "$bang_count" -eq 1 ]; then
	ok "hub has exactly one ! block (one load-time probe)"
else
	bad "hub has $bang_count ! blocks — spec calls for exactly one"
fi

# Only the hub pays for a load-time probe. A ! block in each of five skills would
# run the preflight five times for one question.
for d in "${SKILLS[@]}"; do
	name="$(basename "$d")"
	[ "$name" = "using-agentmail" ] && continue
	# No `|| echo 0` here: grep -c already prints 0 and merely exits 1, so the
	# fallback would concatenate a second 0 and make the comparison non-numeric.
	n="$(grep -c '^```!$' "$d/SKILL.md" 2>/dev/null)"; n="${n:-0}"
	[ "$n" -eq 0 ] && ok "$name: no ! block (the hub owns the load-time probe)" \
		|| bad "$name: has $n ! block(s) — only the hub should probe at load time"
done

# Codex never executes ! blocks, so any file with one must say so.
for d in "${SKILLS[@]}"; do
	name="$(basename "$d")"
	grep -q '^```!$' "$d/SKILL.md" 2>/dev/null || continue
	grep -qi 'Codex does not execute' "$d/SKILL.md" \
		&& ok "$name: tells Codex the ! block did not run" \
		|| bad "$name: has a ! block but never tells Codex it does not execute"
done

echo
echo "== allowed-tools sync =="

allowed_of() { sed -n '/^allowed-tools:/,/^---$/p' "$1"; }

hub_allowed="$(allowed_of "$HUB")"
if printf '%s' "$hub_allowed" | grep -q 'bash \*/scripts/agentmail-preflight.sh'; then
	ok "hub allowed-tools covers the preflight script invoked from the ! block"
else
	bad "hub allowed-tools does not cover scripts/agentmail-preflight.sh" \
		"The ! block runs it at load time; without the grant it prompts on every load."
fi

for cmd in "agentmail inboxes list" "agentmail inboxes:messages list" "agentmail inboxes:messages get"; do
	if printf '%s' "$hub_allowed" | grep -qF "$cmd"; then
		ok "hub allowed-tools grants: $cmd"
	else
		bad "hub allowed-tools missing read command: $cmd"
	fi
done

# `organizations get` must NOT be presented as the auth probe: it succeeds only on
# an organization-scoped key, and using it as one reported a working inbox-scoped
# key as rejected.
if grep -qE '^\|.*Am I authenticated.*organizations get' "$HUB"; then
	bad "the hub still names 'organizations get' as the auth probe" \
		"It 403s on an inbox-scoped key. The probe is 'inboxes list'."
else
	ok "the hub does not name 'organizations get' as the auth probe"
fi

# Any skill that runs a bundled script must allowlist it, or it prompts every
# time — EXCEPT the two that must always prompt. agentmail-signup.sh mints an API
# key and rotates any existing one; agentmail-verify.sh spends one of ten OTP
# attempts. Both are irreversible, so their prompt is the feature, and this
# asserts they stay off the allowlist rather than merely noticing they are.
must_prompt=" agentmail-signup.sh agentmail-verify.sh "
for d in "${SKILLS[@]}"; do
	name="$(basename "$d")"
	a="$(allowed_of "$d/SKILL.md")"
	for s in $(grep -ohE '(scripts)/agentmail-[a-z-]+\.sh' "$d/SKILL.md" 2>/dev/null | sort -u); do
		bn="$(basename "$s")"
		granted=0
		printf '%s' "$a" | grep -qF "$bn" && granted=1
		case "$must_prompt" in
			*" $bn "*)
				[ "$granted" -eq 0 ] \
					&& ok "$name: $bn is deliberately NOT allowlisted (irreversible)" \
					|| bad "$name: allowlisted $bn — it mints a key or spends an OTP attempt" ;;
			*)
				[ "$granted" -eq 1 ] \
					&& ok "$name: allowed-tools covers $bn" \
					|| bad "$name: runs $bn but does not allowlist it" ;;
		esac
	done
done

# The mirror rule, in both directions.
for d in "${SKILLS[@]}"; do
	name="$(basename "$d")"
	y="$d/agents/openai.yaml"
	[ -f "$y" ] || continue
	if grep -q '^disable-model-invocation:' "$d/SKILL.md"; then
		grep -q 'allow_implicit_invocation:[[:space:]]*false' "$y" \
			&& ok "$name: disable-model-invocation is mirrored in openai.yaml" \
			|| bad "$name: disable-model-invocation set but openai.yaml lacks policy.allow_implicit_invocation: false"
	else
		grep -q 'allow_implicit_invocation' "$y" \
			&& bad "$name: openai.yaml restricts implicit invocation but SKILL.md has no disable-model-invocation" \
			       "The two harnesses would disagree about whether this skill can self-trigger." \
			|| ok "$name: no disable-model-invocation, no policy block (harnesses agree)"
	fi
done

echo
echo "== references resolve =="

# A reference can live beside its skill or, when more than one skill needs it, at
# the plugin root. Both are legitimate; a dangling path is not.
for f in "${DOCS[@]}"; do
	base="$(echo "$f" | sed 's#^skills/##; s#/SKILL.md$##')"
	dir="$(dirname "$f")"
	for ref in $(grep -oE 'references/[a-z0-9-]+\.(md|json)' "$f" | sort -u); do
		if [ -f "$dir/$ref" ] || [ -f "$ref" ]; then
			ok "$base → $ref resolves"
		else
			bad "$base references $ref, which does not exist in $dir/ or at the plugin root"
		fi
	done
done

# A plugin-root reference must be reached through the plugin-root token, because
# nothing resolves a bare relative path for the model.
for f in "${DOCS[@]}"; do
	base="$(echo "$f" | sed 's#^skills/##; s#/SKILL.md$##')"
	dir="$(dirname "$f")"
	for ref in $(grep -oE 'references/[a-z0-9-]+\.(md|json)' "$f" | sort -u); do
		[ -f "$dir/$ref" ] && continue          # skill-local, relative is fine
		[ -f "$ref" ] || continue
		if grep -q "CLAUDE_PLUGIN_ROOT}/$ref" "$f"; then
			ok "$base → $ref uses the plugin-root token"
		else
			bad "$base names the shared $ref without \${CLAUDE_PLUGIN_ROOT}/" \
				"There is no implicit base directory for the model to resolve against."
		fi
	done
done

# Shared references must actually be shared — a plugin-root file only one skill
# reads belongs beside that skill.
for ref in references/*.md; do
	[ -f "$ref" ] || continue
	readers="$(grep -l "$(basename "$ref")" skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
	[ "$readers" -ge 2 ] \
		&& ok "$(basename "$ref") is read by $readers skills (earns its place at the plugin root)" \
		|| bad "$(basename "$ref") is read by $readers skill(s) — move it beside that skill"
done

# Nothing resolves a bare relative path for the model, so scripts referenced in
# prose must go through the token form.
for f in "${DOCS[@]}"; do
	base="$(echo "$f" | sed 's#^skills/##; s#/SKILL.md$##')"
	if grep -qE '^\s*bash scripts/' "$f"; then
		bad "$base: a bare relative script path appears in prose" \
			"There is no implicit base directory — use the \$SKILL_DIR/\$PLUGIN_ROOT form."
	fi
done
ok "no bare relative script paths"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
