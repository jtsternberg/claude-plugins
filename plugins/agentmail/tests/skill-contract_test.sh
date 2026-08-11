#!/usr/bin/env bash
# =============================================================================
# Dual-harness contract checks for the agentmail skill.
#
# Enforces AGENTS.md § Dual-Harness Skill Contract mechanically, so a later edit
# that reads fine under Claude Code but silently breaks Codex fails here instead
# of in someone's session.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PLUGIN_ROOT" || exit 1

SKILL="skills/using-agentmail/SKILL.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

echo "== discovery =="

if [ -f "$SKILL" ]; then
	ok "SKILL.md is at the discoverable path (skills/<name>/SKILL.md)"
else
	bad "SKILL.md missing at $SKILL"
	echo "1 passed, 1 failed"; exit 1
fi

for f in .claude-plugin/plugin.json skills/using-agentmail/agents/openai.yaml; do
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

echo
echo "== frontmatter =="

frontmatter() { sed -n '2,/^---$/p' "$SKILL"; }

for key in name description when_to_use argument-hint allowed-tools; do
	if frontmatter | grep -q "^${key}:"; then
		ok "frontmatter has $key"
	else
		bad "frontmatter missing $key"
	fi
done

if frontmatter | grep -q '^name: using-agentmail$'; then
	ok "frontmatter name is using-agentmail"
else
	bad "frontmatter name is not using-agentmail (invocation path depends on it)"
fi

# Codex ignores when_to_use entirely, so the routing terms have to be in
# description or Codex will never route to this skill.
desc="$(frontmatter | sed -n 's/^description: *//p')"
missing_terms=""
for term in email inbox send reply forward draft AgentMail; do
	printf '%s' "$desc" | grep -qi -- "$term" || missing_terms="$missing_terms $term"
done
if [ -z "$missing_terms" ]; then
	ok "description carries the Codex routing terms"
else
	bad "description missing Codex routing terms:$missing_terms" \
	    "Codex does not read when_to_use — these must be in description."
fi

echo
echo "== path tokens =="

# Bare token only. A shell-default wrapper stops Claude Code resolving it.
if grep -q 'CLAUDE_SKILL_DIR:-' "$SKILL" || grep -rq 'CLAUDE_SKILL_DIR:-' skills/using-agentmail/references/ 2>/dev/null; then
	bad "a CLAUDE_SKILL_DIR token is wrapped in a shell default (\${...:-...})" \
	    "Claude Code resolves the bare token mechanically; a wrapper defeats it."
else
	ok "no shell-default wrapper around CLAUDE_SKILL_DIR"
fi

# The skill token names the skill's own directory; traversing out of it is
# unsupported (that is what CLAUDE_PLUGIN_ROOT is for).
if grep -q 'CLAUDE_SKILL_DIR}/\.\.' "$SKILL" || grep -rq 'CLAUDE_SKILL_DIR}/\.\.' skills/using-agentmail/references/ 2>/dev/null; then
	bad "traversal out of the skill directory (\${CLAUDE_SKILL_DIR}/../)"
else
	ok "no traversal out of the skill directory"
fi

# Every file that uses $SKILL_DIR must also assign it — Codex shells keep no
# state between independently executed blocks.
for f in "$SKILL" skills/using-agentmail/references/*.md; do
	[ -f "$f" ] || continue
	uses=$(grep -c '"\$SKILL_DIR' "$f" 2>/dev/null || true)
	assigns=$(grep -c '^SKILL_DIR="\${CLAUDE_SKILL_DIR}"$' "$f" 2>/dev/null || true)
	if [ "${uses:-0}" -eq 0 ]; then
		ok "$(basename "$f"): no \$SKILL_DIR use (nothing to assign)"
	elif [ "${assigns:-0}" -ge 1 ]; then
		ok "$(basename "$f"): $uses use(s), $assigns assignment(s)"
	else
		bad "$(basename "$f") uses \$SKILL_DIR but never assigns it"
	fi
done

# Every assignment needs an adjacent Codex substitution instruction, and that
# instruction must NOT itself contain the token.
assign_lines=$(grep -n '^SKILL_DIR="\${CLAUDE_SKILL_DIR}"$' "$SKILL" | cut -d: -f1)
codex_ok=1
for ln in $assign_lines; do
	prev=$((ln - 1))
	line="$(sed -n "${prev}p" "$SKILL")"
	printf '%s' "$line" | grep -qi 'codex' || codex_ok=0
	printf '%s' "$line" | grep -q 'CLAUDE_SKILL_DIR' && codex_ok=0
done
if [ -n "$assign_lines" ] && [ "$codex_ok" -eq 1 ]; then
	ok "every SKILL_DIR assignment has an adjacent Codex note that omits the token"
elif [ -z "$assign_lines" ]; then
	bad "no SKILL_DIR assignment found in SKILL.md"
else
	bad "a SKILL_DIR assignment lacks an adjacent Codex note, or the note repeats the token"
fi

echo
echo "== dynamic context (! blocks) =="

# A compound operator in a ! block trips Claude Code's shell-operator permission
# gate at load time. This is why fetch-docs routes its --check through a script.
# Multiple LINES are fine; operators are not.
# Comment lines are stripped first: the Codex substitution note contains a
# semicolon as ordinary English punctuation, and a comment cannot trip a shell
# gate. Only executable lines are checked.
bang_bodies="$(awk '/^```!$/{f=1;next} /^```$/{f=0} f' "$SKILL")"
bang_exec="$(printf '%s\n' "$bang_bodies" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$')"
if [ -z "$bang_bodies" ]; then
	bad "no ! block found — the skill should inject live preflight context"
else
	ok "! block present"
	if printf '%s' "$bang_exec" | grep -qE '&&|\|\||[^|]\|[^|]|;'; then
		bad "a ! block has a compound shell operator on an executable line (&&, ||, |, ;)" \
		    "$(printf '%s' "$bang_exec" | grep -nE '&&|\|\||[^|]\|[^|]|;' | head -3)"
	else
		ok "no compound shell operator on any executable ! block line"
	fi
fi

bang_count="$(grep -c '^```!$' "$SKILL")"
if [ "$bang_count" -eq 1 ]; then
	ok "exactly one ! block (one load-time probe)"
else
	bad "$bang_count ! blocks — spec calls for exactly one"
fi

# Codex never executes ! blocks, so the skill must say so.
if grep -qi 'Codex does not execute' "$SKILL"; then
	ok "SKILL.md tells Codex the ! block did not run"
else
	bad "SKILL.md does not tell Codex that ! blocks do not execute for it"
fi

echo
echo "== allowed-tools sync =="

allowed="$(sed -n '/^allowed-tools:/,/^---$/p' "$SKILL")"

# Every agentmail command the skill actually runs in an executable block must be
# covered by an allow pattern OR be a deliberate prompt-on-use command. Both
# directions matter: an uncovered read is friction, an allowed send is a hazard.
if printf '%s' "$allowed" | grep -q 'bash \*/scripts/agentmail-preflight.sh'; then
	ok "allowed-tools covers the preflight script invoked from the ! block"
else
	bad "allowed-tools does not cover scripts/agentmail-preflight.sh" \
	    "The ! block runs it at load time; without the grant it prompts on every load."
fi

for cmd in "agentmail organizations get" "agentmail inboxes list" "agentmail inboxes:messages list" "agentmail inboxes:messages get"; do
	if printf '%s' "$allowed" | grep -qF "$cmd"; then
		ok "allowed-tools grants: $cmd"
	else
		bad "allowed-tools missing read command: $cmd"
	fi
done

# The mirror rule, checked in the negative direction: no disable-model-invocation
# means openai.yaml must NOT carry a policy block, because the skill is meant to
# be implicitly invocable under both harnesses.
if grep -q '^disable-model-invocation:' "$SKILL"; then
	if grep -q 'allow_implicit_invocation:[[:space:]]*false' skills/using-agentmail/agents/openai.yaml; then
		ok "disable-model-invocation is mirrored in openai.yaml"
	else
		bad "disable-model-invocation set but openai.yaml lacks policy.allow_implicit_invocation: false"
	fi
else
	if grep -q 'allow_implicit_invocation' skills/using-agentmail/agents/openai.yaml; then
		bad "openai.yaml restricts implicit invocation but SKILL.md has no disable-model-invocation" \
		    "The two harnesses would disagree about whether this skill can self-trigger."
	else
		ok "no disable-model-invocation, and openai.yaml has no policy block (harnesses agree)"
	fi
fi

echo
echo "== references resolve =="

for ref in $(grep -oE 'references/[a-z-]+\.md' "$SKILL" | sort -u); do
	if [ -f "skills/using-agentmail/$ref" ]; then
		ok "$ref exists"
	else
		bad "$ref is referenced but does not exist"
	fi
done

# Nothing resolves a bare relative path for the model, so scripts referenced in
# prose must go through the token form.
if grep -qE '^\s*bash scripts/' "$SKILL"; then
	bad "a bare relative script path appears in SKILL.md" \
	    "There is no implicit base directory — use the \$SKILL_DIR form."
else
	ok "no bare relative script paths"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
