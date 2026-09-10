import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// The plugin inventory is a constant with one source — `.claude-plugin/marketplace.json`
// — that README.md and docs/compatibility.md each restate in prose. Hand-maintained,
// those numbers drift silently: the support matrix went a release without a maestro row
// while three README sentences quoted a stale total. This canary asserts the prose and
// the matrix against the catalogs themselves.

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const readJson = (relative) => JSON.parse(readFileSync(join(repoRoot, relative), 'utf8'));
const readText = (relative) => readFileSync(join(repoRoot, relative), 'utf8');

const claudeNames = readJson('.claude-plugin/marketplace.json').plugins.map((p) => p.name);
const codexNames = readJson('.agents/plugins/marketplace.json').plugins.map((p) => p.name);
const bothNames = [...new Set([...claudeNames, ...codexNames])];

test('README quotes the live Claude-catalog and combined plugin counts', () => {
	const readme = readText('README.md');
	assert.match(readme, new RegExp(`install any of its ${claudeNames.length} listed plugins`));
	assert.match(readme, new RegExp(`all ${bothNames.length} plugin names`));
	assert.match(readme, new RegExp(`^${bothNames.length}-name inventory`, 'm'));
});

test('the compatibility guide quotes the live catalog counts', () => {
	const guide = readText('docs/compatibility.md');
	assert.match(
		guide,
		new RegExp(`${claudeNames.length} entries in the Claude Code catalog, ${bothNames.length} names across both`),
	);
});

test('the support matrix carries exactly one row per catalogued plugin', () => {
	const guide = readText('docs/compatibility.md');
	const matrix = guide.slice(guide.indexOf('## Plugin support matrix'));
	assert.notEqual(matrix, '', 'the support matrix heading moved or was renamed');

	const rows = [...matrix.matchAll(/^\| \[([^\]]+)\]/gm)].map((m) => m[1]);
	assert.deepEqual(
		rows.filter((name) => !bothNames.includes(name)),
		[],
		'matrix rows naming a plugin neither catalog offers',
	);
	assert.deepEqual(
		bothNames.filter((name) => !rows.includes(name)),
		[],
		'catalogued plugins with no matrix row',
	);
});
