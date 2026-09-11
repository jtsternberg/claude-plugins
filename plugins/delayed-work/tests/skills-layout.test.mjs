import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const skillFile = join(pluginRoot, 'skills', 'until', 'SKILL.md');

test('until ships as a model-invocable skill with no legacy command surface', () => {
	const content = readFileSync(skillFile, 'utf8');
	assert.match(content, /^name: until$/m);
	assert.doesNotMatch(content, /disable-model-invocation/);
	// An openai.yaml would only be needed to mirror explicit-only policy.
	assert.equal(existsSync(join(pluginRoot, 'skills', 'until', 'agents', 'openai.yaml')), false);

	const commandsDirectory = join(pluginRoot, 'commands');
	const commandFiles = existsSync(commandsDirectory)
		? readdirSync(commandsDirectory).filter((file) => file.endsWith('.md'))
		: [];
	assert.deepEqual(commandFiles, []);
});

test('until preserves cross-harness contracts and its deliberate mechanics', () => {
	const content = readFileSync(skillFile, 'utf8');
	assert.match(content, /\$ARGUMENTS/);
	assert.match(content, /Codex: if that token is not substituted/);
	assert.match(content, /argument-hint: "\[--caffeinate\] <when> <what to run>"/);
	assert.match(content, /Caffeination is off by default/);
	assert.match(content, /only when the\s+invocation includes the standalone `--caffeinate` flag/);

	// A single long sleep is the bug this skill exists to prevent; the loop must stay.
	assert.match(content, /while \[ "\$\(date \+%s\)" -lt "\$TARGET" \]; do sleep 30; done/);
	assert.match(content, /persistent: true/);
	assert.match(content, /timeout_ms: 3600000/);
	assert.match(content, /date -j -f/);
	// The notification arrives bare, so the emitted line has to name the payload.
	assert.match(content, /FIRE/);
	// send-at is the inverse and must stay distinguished from this skill.
	assert.match(content, /send-at/);
});
