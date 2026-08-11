import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const SCRIPT = path.join(REPO, 'scripts/inventory-codex-namespaces.mjs');
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'codex-namespace-'));
const write = (file, contents) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, contents); };
const skill = name => `---\nname: ${name}\ndescription: test\n---\n`;

test('inventory finds standalone and marketplace collisions without exposing fixture paths', () => {
	const root = tmp();
	try {
		const home = path.join(root, 'home');
		const workspace = path.join(root, 'workspace');
		const codexHome = path.join(home, '.codex');
		write(path.join(workspace, '.agents/skills/shared/SKILL.md'), skill('shared'));
		write(path.join(home, '.agents/skills/shared/SKILL.md'), skill('shared'));
		write(path.join(codexHome, 'skills/system-only/SKILL.md'), skill('system-only'));
		write(path.join(codexHome, 'plugins/cache/alpha/widget/1.0.0/skills/shared/SKILL.md'), skill('shared'));
		const alpha = path.join(root, 'alpha-marketplace');
		const beta = path.join(root, 'beta-marketplace');
		write(path.join(alpha, '.agents/plugins/marketplace.json'), JSON.stringify({ plugins: [{ name: 'widget' }, { name: 'alpha-only' }] }));
		write(path.join(beta, '.claude-plugin/marketplace.json'), JSON.stringify({ plugins: [{ name: 'widget' }, { name: 'beta-only' }] }));
		write(path.join(root, 'plugins.json'), JSON.stringify({ installed: [{ name: 'widget', marketplaceName: 'alpha', version: '1.0.0', enabled: true }] }));
		write(path.join(root, 'marketplaces.json'), JSON.stringify({ marketplaces: [{ name: 'alpha', root: alpha }, { name: 'beta', root: beta }] }));
		const out = execFileSync('node', [SCRIPT, '--workspace', workspace, '--repo-root', workspace, '--home', home, '--codex-home', codexHome, '--admin-skills', path.join(root, 'admin'), '--plugin-list-json', path.join(root, 'plugins.json'), '--marketplaces-json', path.join(root, 'marketplaces.json')], { encoding: 'utf8' });
		assert.match(out, /\| `shared` \| user \.agents\/skills<br>widget@alpha<br>workspace \.agents\/skills/);
		assert.match(out, /consolidate duplicate standalone copies before relying on an unqualified invocation/);
		assert.match(out, /\| `widget` \| alpha<br>beta \| accept: marketplace-qualified plugin IDs are unambiguous/);
		assert.ok(!out.includes(root), 'report must not leak machine-specific roots');
		assert.match(out, /\| administrator skills \| 0 \| `<EXTERNAL>` \|/);
	} finally { fs.rmSync(root, { recursive: true, force: true }); }
});
