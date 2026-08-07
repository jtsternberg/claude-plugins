import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const pluginRoot = path.resolve(import.meta.dirname, '..');
const skillRoot = path.join(pluginRoot, 'skills', 'walk-through-work-history');
const skill = fs.readFileSync(path.join(skillRoot, 'SKILL.md'), 'utf8');
const reference = fs.readFileSync(path.join(skillRoot, 'references', 'github-pr.md'), 'utf8');
const openai = fs.readFileSync(path.join(skillRoot, 'agents', 'openai.yaml'), 'utf8');
const readme = fs.readFileSync(path.join(pluginRoot, 'README.md'), 'utf8');
const manifest = JSON.parse(fs.readFileSync(path.join(pluginRoot, '.claude-plugin', 'plugin.json'), 'utf8'));

test('packages the walkthrough as a versioned pr-workflow skill', () => {
	assert.equal(manifest.name, 'pr-workflow');
	assert.equal(manifest.version, '1.8.0');
	assert.match(manifest.description, /history walkthroughs/);
	assert.match(skill, /^---\nname: walk-through-work-history\ndescription: .+\n---\n/);
	assert.match(skill, /Ready to \*\*turn the page\*\*\?/);
});

test('resolves the GitHub reference in both Claude and Codex', () => {
	assert.match(skill, /\$\{CLAUDE_SKILL_DIR\}\/references\/github-pr\.md/);
	assert.match(skill, /Codex: resolve `references\/github-pr\.md` relative to/);
	assert.doesNotMatch(skill, /\$\{CLAUDE_SKILL_DIR:-/);
	assert.match(reference, /gh api --paginate/);
});

test('ships Codex metadata with plugin-qualified invocation', () => {
	assert.match(openai, /default_prompt: "Use \$pr-workflow:walk-through-work-history /);
	assert.match(openai, /allow_implicit_invocation: true/);
	assert.match(readme, /\/pr-workflow:walk-through-work-history/);
	assert.match(readme, /\$pr-workflow:walk-through-work-history/);
});
