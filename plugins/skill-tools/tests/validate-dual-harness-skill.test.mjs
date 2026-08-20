import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const agents = fs.readFileSync(path.join(REPO, 'AGENTS.md'), 'utf8');
const skillRoot = path.join(REPO, 'plugins/skill-tools/skills/validate-dual-harness-skill');
const skill = fs.readFileSync(path.join(skillRoot, 'SKILL.md'), 'utf8');
const codexMetadata = fs.readFileSync(path.join(skillRoot, 'agents/openai.yaml'), 'utf8');
const userFacingDocs = [
	agents,
	fs.readFileSync(path.join(REPO, 'plugins/beads-workflow/README.md'), 'utf8'),
	fs.readFileSync(path.join(REPO, 'plugins/git-commits/README.md'), 'utf8'),
	fs.readFileSync(path.join(REPO, 'plugins/pr-workflow/bundle/README.md'), 'utf8'),
	fs.readFileSync(path.join(REPO, 'plugins/hotline/README.md'), 'utf8'),
	fs.readFileSync(path.join(REPO, 'plugins/skill-tools/README.md'), 'utf8'),
].join('\n');

test('repository authoring rules require the dual-harness validator', () => {
	assert.match(agents, /^## Dual-Harness Skill Contract$/m);
	assert.match(agents, /Every new or edited skill must preserve behavior under both Claude Code and Codex/);
	assert.match(agents, /run `validate-dual-harness-skill`/);
	assert.match(agents, /literal `\$ARGUMENTS`/);
	assert.match(agents, /policy\.allow_implicit_invocation: false/);
	assert.match(agents, /Codex invokes it as `\$<plugin-name>:<frontmatter-name>`/);
});

test('validator covers the known Claude and Codex divergence points', () => {
	for (const contract of [
		'$ARGUMENTS',
		'CLAUDE_SKILL_DIR',
		'CLAUDE_PLUGIN_ROOT',
		'when_to_use',
		'argument-hint',
		'allowed-tools',
		'policy.allow_implicit_invocation: false',
		'commands/*.md',
		'bash tests/run-all.sh',
	]) {
		assert.ok(skill.includes(contract), `validator is missing ${contract}`);
	}
	assert.match(skill, /representative installed-plugin probe under both Claude Code and Codex/);
	assert.equal(skill.match(/\$ARGUMENTS/g)?.length, 1, 'only the invocation slot may contain the substitutable argument token');
	assert.match(codexMetadata, /allow_implicit_invocation: false/);
});

test('user-facing Codex examples distinguish native plugins from standalone skills', () => {
	assert.doesNotMatch(userFacingDocs, /Codex[^\n]*`?\$<(?:frontmatter-name|skill-name|skill)>/);
	for (const invocation of [
		'$skill-tools:validate-dual-harness-skill',
		'$address-pr-comments:address-pr-comments',
		'$hotline:<skill-name>',
		'$tackle-epic',
		'$commit-staged',
	]) {
		assert.ok(userFacingDocs.includes(invocation), `missing Codex example ${invocation}`);
	}
	assert.doesNotMatch(userFacingDocs, /\$beads-workflow:(?:tackle-epic|fix-findings-beads-tasks)/);
	assert.doesNotMatch(userFacingDocs, /\$git-commits:(?:commit-staged|commit-unstaged)/);
});
