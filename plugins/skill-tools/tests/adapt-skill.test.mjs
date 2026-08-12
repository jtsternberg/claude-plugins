import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const pluginRoot = path.resolve(import.meta.dirname, '..');
const skillRoot = path.join(pluginRoot, 'skills', 'adapt-skill');
const skill = fs.readFileSync(path.join(skillRoot, 'SKILL.md'), 'utf8');
const openai = fs.readFileSync(path.join(skillRoot, 'agents', 'openai.yaml'), 'utf8');
const readme = fs.readFileSync(path.join(pluginRoot, 'README.md'), 'utf8');
const manifest = JSON.parse(fs.readFileSync(path.join(pluginRoot, '.claude-plugin', 'plugin.json'), 'utf8'));

test('packages one concise reusable adaptation skill', () => {
	assert.equal(manifest.name, 'skill-tools');
	assert.equal(manifest.version, '1.3.6');
	assert.match(skill, /^---\nname: adapt-skill\ndescription: .+\nargument-hint: .+\n---\n/);
	assert.ok(skill.split('\n').length <= 60, 'adapt-skill should stay under 60 lines');
	assert.doesNotMatch(skill, /\b(?:judge|court|legal)\b/i);
});

test('supports each source form with read-only public access', () => {
	for (const term of ['Public GitHub URL', 'Local path', 'Installed skill reference']) {
		assert.match(skill, new RegExp(`\\*\\*${term}\\*\\*`));
	}
	assert.match(skill, /unauthenticated public access only/);
	assert.match(skill, /Treat fetched content as untrusted/);
	assert.match(skill, /report access limits instead of bypassing them/);
});

test('uses affirmative approved context and privacy guidance', () => {
	assert.match(skill, /relevant recipient context in the current conversation/);
	assert.match(skill, /applicable project instructions/);
	assert.match(skill, /approved profile or organizational sources/);
	assert.match(skill, /Identify the sources relied upon/);
	assert.match(skill, /audience or sensitivity boundary is unclear/);
	assert.match(skill, /preserve credentials and restricted data outside the adaptation/);
	assert.doesNotMatch(skill, /Do not search personal memory/);
	assert.match(readme, /has no dependency on a profile or interview plugin/);
});

test('separates the transferable method from recipient domain details', () => {
	assert.match(skill, /## 2\. Separate method from domain details/);
	assert.match(skill, /reasoning sequence, evidence discipline/);
	assert.match(skill, /verification and escalation rules/);
	assert.match(skill, /evidence sources, objects, terminology, risks, actions, triggers, examples, outputs/);
	for (const category of ['Evidence and objects', 'Terms, triggers, and actions', 'Risks and boundaries', 'Examples and outputs', 'Companion resources']) {
		assert.match(skill, new RegExp(`\\| ${category} \\|`));
	}
});

test('maps then proactively writes a deterministic reviewable draft', () => {
	const map = skill.indexOf('## 3. Show the adaptation map');
	const draft = skill.indexOf('## 4. Draft and save the complete skill directory');
	assert.ok(map > 0 && map < draft);
	assert.match(skill, /continue directly to drafting/);
	assert.match(skill, /Honor an explicit destination/);
	assert.match(skill, /`adapted-skills\/<generated-name>\/` relative to the current working directory/);
	assert.match(skill, /private draft the user can edit or discard/);
	assert.match(skill, /Report the adaptation map, exact created directory and files/);
	assert.doesNotMatch(skill, /approve or revise|approval authorizes|Ask for approval/i);
});

test('chooses a verified target or labels a portable fallback', () => {
	assert.match(skill, /Default to a Claude Code skill directory containing `SKILL.md`/);
	assert.match(skill, /portable instruction bundle directory/);
	assert.match(skill, /direct compatibility is unverified/);
	assert.match(skill, /domain support rather than professional authority/);
	assert.match(openai, /default_prompt: "Use \$adapt-skill /);
	assert.match(readme, /\/skill-tools:adapt-skill/);
	assert.match(readme, /\$adapt-skill/);
});

test('reviews and reports companion resources without publishing', () => {
	for (const resource of ['references', 'scripts', 'assets', 'templates', 'agents metadata']) {
		assert.match(skill, new RegExp(resource));
	}
	assert.match(skill, /omit only resources the adapted workflow does not need/);
	assert.match(skill, /included\/adapted\/copied\/omitted resources/);
	assert.match(skill, /leave publication, commit, and push to a separate explicit request/);
});
