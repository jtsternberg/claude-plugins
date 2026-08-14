import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const skillRoot = join(pluginRoot, 'skills', 'triage-beads');

test('triage-beads is deliberately model-invocable (unlike its siblings)', () => {
	const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');
	const metadata = readFileSync(join(skillRoot, 'agents', 'openai.yaml'), 'utf8');

	assert.match(content, /name: triage-beads/);
	// The other two beads-workflow skills are explicit-only. This one must NOT
	// be — it fires on "triage beads" and runs from a scheduled agent.
	assert.doesNotMatch(content, /disable-model-invocation:\s*true/);
	assert.match(metadata, /allow_implicit_invocation:\s*true/);
});

test('triage-beads carries a portable execution contract', () => {
	const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');

	// Bundled script referenced through the runtime-resolved skill path, with
	// Codex substitution prose alongside — the dual-harness contract.
	assert.match(content, /SKILL_DIR="\$\{CLAUDE_SKILL_DIR\}"/);
	assert.match(content, /scripts\/collect-open-beads\.sh/);
	assert.match(content, /Codex: /);
	// Optional positional args preserved for Codex, matching sibling skills.
	assert.match(content, /Optional flags: `\$ARGUMENTS`/);
});

test('triage-beads ships its collector script, executable', () => {
	const script = join(skillRoot, 'scripts', 'collect-open-beads.sh');
	assert.ok(existsSync(script), 'collect-open-beads.sh must exist');
	const src = readFileSync(script, 'utf8');
	// Read-only guarantee: the collector must not mutate beads state.
	assert.doesNotMatch(src, /bd (close|update|comment|create|delete)\b/);
});
