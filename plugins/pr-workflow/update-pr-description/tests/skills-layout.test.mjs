import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));

test('update-pr-description ships as an explicit-only skill', () => {
	const skillRoot = join(pluginRoot, 'skills', 'update-pr-description');
	const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');
	const metadata = readFileSync(join(skillRoot, 'agents', 'openai.yaml'), 'utf8');

	assert.match(content, /name: update-pr-description/);
	assert.match(content, /disable-model-invocation: true/);
	assert.match(metadata, /allow_implicit_invocation: false/);

	const commandsDirectory = join(pluginRoot, 'commands');
	const commandFiles = existsSync(commandsDirectory)
		? readdirSync(commandsDirectory).filter(file => file.endsWith('.md'))
		: [];
	assert.deepEqual(commandFiles, []);
});

test('update-pr-description preserves safe cross-harness contracts', () => {
	const content = readFileSync(join(pluginRoot, 'skills', 'update-pr-description', 'SKILL.md'), 'utf8');
	assert.match(content, /\$ARGUMENTS/);
	assert.match(content, /Codex: if the invocation text above is not populated/);
	assert.match(content, /argument-hint: "\[date\/commit-hash \| --force\]"/);
	assert.match(content, /mktemp -d/);
	assert.match(content, /git diff --no-index/);
	assert.doesNotMatch(content, /@docs\//);
});
