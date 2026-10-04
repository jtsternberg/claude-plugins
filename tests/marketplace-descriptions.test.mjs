import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Each `.claude-plugin/marketplace.json` entry carries a copy of its plugin's
// `plugin.json` description, because third-party directories (aitmpl.com's
// generator, for one) read the catalog entry and never open the manifest — an
// entry without it lists blank. The manifest is the source; this pins the copy.

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const readJson = (relative) => JSON.parse(readFileSync(join(repoRoot, relative), 'utf8'));

const entries = readJson('.claude-plugin/marketplace.json').plugins;

for (const entry of entries) {
	test(`marketplace description for ${entry.name} matches its plugin.json`, () => {
		const manifest = readJson(join(entry.source, '.claude-plugin', 'plugin.json'));
		assert.ok(manifest.description, `${entry.source}/.claude-plugin/plugin.json has no description`);
		assert.equal(
			entry.description,
			manifest.description,
			`copy ${entry.source}/.claude-plugin/plugin.json's description into its marketplace.json entry`,
		);
	});
}
