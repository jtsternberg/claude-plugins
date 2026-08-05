import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const skills = ['fix-findings-beads-tasks', 'tackle-epic'];

test('beads-workflow exposes its workflows as explicit-only skills', () => {
	for (const skill of skills) {
		const skillRoot = join(pluginRoot, 'skills', skill);
		const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');
		const metadata = readFileSync(join(skillRoot, 'agents', 'openai.yaml'), 'utf8');

		assert.match(content, new RegExp(`name: ${skill}`));
		assert.match(content, /disable-model-invocation: true/);
		assert.match(metadata, /allow_implicit_invocation: false/);
	}

	const commandsDirectory = join(pluginRoot, 'commands');
	const commandFiles = existsSync(commandsDirectory)
		? readdirSync(commandsDirectory).filter(file => file.endsWith('.md'))
		: [];
	assert.deepEqual(commandFiles, []);
});

test('converted beads skills retain portable execution contracts', () => {
	const fixFindings = readFileSync(join(pluginRoot, 'skills', 'fix-findings-beads-tasks', 'SKILL.md'), 'utf8');
	const tackleEpic = readFileSync(join(pluginRoot, 'skills', 'tackle-epic', 'SKILL.md'), 'utf8');

	assert.match(fixFindings, /^\$ARGUMENTS$/m);
	assert.match(fixFindings, /Codex: if `\$ARGUMENTS` above is not substituted/);
	assert.match(fixFindings, /`AGENTS\.md`, `CLAUDE\.md`/);
	assert.match(tackleEpic, /optional flags: `\$ARGUMENTS`/);
	assert.match(tackleEpic, /Codex: if `\$ARGUMENTS` above is not substituted/);
	assert.doesNotMatch(tackleEpic, /Task tool|Generated with \[Claude Code/);
	assert.match(tackleEpic, /branch_name="\$\(git branch --show-current\)"/);
	assert.match(tackleEpic, /git diff --name-only "\$base_ref"\.\.\.HEAD/);
	assert.match(tackleEpic, /git push -u origin "\$branch_name"/);
});
