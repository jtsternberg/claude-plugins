import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const skills = ['commit-staged', 'commit-unstaged'];

test('git-commits exposes both workflows as skills, not legacy commands', () => {
	for (const skill of skills) {
		const skillPath = join(pluginRoot, 'skills', skill, 'SKILL.md');
		assert.ok(existsSync(skillPath), `${skill} skill exists`);

		const content = readFileSync(skillPath, 'utf8');
		assert.match(content, new RegExp(`name: ${skill}`));
		assert.match(content, /disable-model-invocation: true/);
		assert.match(content, /allowed-tools: \[Bash\]/);
		assert.match(content, /argument-hint: "Optional commit message/);
		assert.match(content, /\*\*Arguments provided:\*\* \$ARGUMENTS/);
		assert.match(content, /Codex: if `\$ARGUMENTS` above is not substituted/);
	}

	const commandsDirectory = join(pluginRoot, 'commands');
	const commandFiles = existsSync(commandsDirectory)
		? readdirSync(commandsDirectory).filter((file) => file.endsWith('.md'))
		: [];
	assert.deepEqual(commandFiles, []);
});
