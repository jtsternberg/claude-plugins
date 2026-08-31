import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const skillRoot = join(pluginRoot, 'skills', 'tripwire-scan');

const isExecutable = (p) => (statSync(p).mode & 0o111) !== 0;

test('tripwire-scan is model-invocable (like triage-beads, unlike the workflows)', () => {
	const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');
	const metadata = readFileSync(join(skillRoot, 'agents', 'openai.yaml'), 'utf8');

	assert.match(content, /name: tripwire-scan/);
	assert.doesNotMatch(content, /disable-model-invocation:\s*true/);
	assert.match(metadata, /allow_implicit_invocation:\s*true/);
});

test('tripwire-scan carries a portable execution contract via the PLUGIN root', () => {
	const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');

	// The matcher is a SHARED script at the plugin root (the hook uses it too),
	// so the skill resolves it through ${CLAUDE_PLUGIN_ROOT}, not the skill token.
	assert.match(content, /PLUGIN_ROOT="\$\{CLAUDE_PLUGIN_ROOT\}"/);
	assert.match(content, /scripts\/tripwire-match\.sh/);
	assert.match(content, /Codex: /);
	assert.match(content, /Optional diff spec: `\$ARGUMENTS`/);
});

test('shared matcher + enumerator ship at the plugin root, executable, read-only', () => {
	const matcher = join(pluginRoot, 'scripts', 'tripwire-match.sh');
	const enumerate = join(pluginRoot, 'scripts', 'bd-enumerate.sh');
	for (const s of [matcher, enumerate]) {
		assert.ok(existsSync(s), `${s} must exist`);
		assert.ok(isExecutable(s), `${s} must be executable`);
	}
	// Neither script may mutate beads state — they only ever query.
	assert.doesNotMatch(readFileSync(matcher, 'utf8'), /bd (close|update|comment|create|delete)\b/);
	const enumSrc = readFileSync(enumerate, 'utf8');
	assert.doesNotMatch(enumSrc, /bd (close|update|comment|create|delete)\b/);
	assert.match(enumSrc, /bd list/);
});

test('triage-beads and tripwire-scan share ONE enumeration path (no forked bd list)', () => {
	// collect-open-beads.sh must delegate to the shared bd-enumerate.sh rather
	// than running its own `bd list` — the repo contract for a second caller.
	const collect = readFileSync(
		join(pluginRoot, 'skills', 'triage-beads', 'scripts', 'collect-open-beads.sh'), 'utf8');
	assert.match(collect, /bd-enumerate\.sh/);
	assert.doesNotMatch(collect, /^\s*bd list\b/m);
});

test('tripwire-scan ships a PostToolUse hook wired to the shared matcher', () => {
	const hooksPath = join(pluginRoot, 'hooks', 'hooks.json');
	assert.ok(existsSync(hooksPath), 'hooks/hooks.json must exist');
	const hooks = JSON.parse(readFileSync(hooksPath, 'utf8'));

	const entries = hooks?.hooks?.PostToolUse;
	assert.ok(Array.isArray(entries) && entries.length > 0, 'a PostToolUse entry must exist');
	const entry = entries[0];
	assert.match(entry.matcher, /Edit\|Write\|MultiEdit/);
	const cmd = entry.hooks[0].command;
	assert.match(cmd, /\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/scripts\/tripwire-posttooluse\.sh/);

	const hookScript = join(pluginRoot, 'hooks', 'scripts', 'tripwire-posttooluse.sh');
	assert.ok(existsSync(hookScript), 'the hook script must exist');
	assert.ok(isExecutable(hookScript), 'the hook script must be executable');
	const src = readFileSync(hookScript, 'utf8');
	// It runs the shared matcher, never a second copy of the logic.
	assert.match(src, /scripts\/tripwire-match\.sh/);
	// The once-per-file-per-session throttle keys off the real session_id, not pid/cwd.
	assert.match(src, /session_id/);
	assert.match(src, /SESSION_ID=\$\(json_get session_id\)/);
	// It must never mutate beads state.
	assert.doesNotMatch(src, /bd (close|update|comment|create|delete)\b/);
});
