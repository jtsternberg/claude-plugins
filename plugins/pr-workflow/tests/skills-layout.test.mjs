import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const convertedSkills = ['address-pr-comments', 'address-pr-comments-human', 'update-pr-description'];

test('pr-workflow exposes its former commands as explicit-only skills', () => {
	for (const skill of convertedSkills) {
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

test('converted PR skills preserve safe cross-harness contracts', () => {
	const automatic = readFileSync(join(pluginRoot, 'skills', 'address-pr-comments', 'SKILL.md'), 'utf8');
	const human = readFileSync(join(pluginRoot, 'skills', 'address-pr-comments-human', 'SKILL.md'), 'utf8');
	const updateDescription = readFileSync(join(pluginRoot, 'skills', 'update-pr-description', 'SKILL.md'), 'utf8');

	for (const content of [automatic, human, updateDescription]) {
		assert.match(content, /\$ARGUMENTS/);
		assert.match(content, /Codex: if `\$ARGUMENTS` above is not substituted/);
	}

	for (const content of [automatic, human]) {
		assert.match(content, /review_thread_comment/);
		assert.match(content, /issue_comment/);
		assert.match(content, /top_level_review/);
		assert.match(content, /comments\/{comment_id}\/replies -F body=@<reply-file>/);
		assert.match(content, /issues\/{pr_number}\/comments -F body=@<reply-file>/);
		assert.doesNotMatch(content, /-f body="<reply>"/);
	}

	assert.match(human, /Do NOT push commits or post replies until the user approves/);
	assert.match(human, /remove only the validated `human-in-loop-drafts\/pr-\{number\}\/` directory/);
	assert.doesNotMatch(human, /Delete the `human-in-loop-drafts\/` directory/);

	assert.match(updateDescription, /argument-hint: "\[date\/commit-hash \| --force\]"/);
	assert.match(updateDescription, /mktemp -d/);
	assert.match(updateDescription, /git diff --no-index/);
	assert.doesNotMatch(updateDescription, /@docs\//);
});
