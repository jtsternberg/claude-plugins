import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectExplicitInvocationPolicy, policyErrors } from '../../../scripts/audit-explicit-invocation-policy.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const PLUGINS = path.join(REPO, 'plugins');
const COMPONENT_FIELDS = ['skills', 'commands', 'agents', 'apps', 'mcpServers', 'hooks'];
// Add only deliberately harness-specific release splits, with a concrete rationale.
const DUAL_PUBLISHED_VERSION_EXCEPTIONS = new Map();

function directories(dir) {
	return fs.readdirSync(dir, { withFileTypes: true })
		.filter(entry => entry.isDirectory())
		.map(entry => entry.name)
		.sort();
}

function readJson(file) {
	return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function filesBelow(dir) {
	if (!fs.existsSync(dir)) return [];
	return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
		const file = path.join(dir, entry.name);
		return entry.isDirectory() ? filesBelow(file) : [file];
	});
}

function assertSafeExistingPath(pluginRoot, value, label) {
	assert.equal(typeof value, 'string', `${label} must be a path string`);
	assert.ok(value.startsWith('./'), `${label} must start with ./`);
	const resolved = path.resolve(pluginRoot, value);
	assert.ok(resolved.startsWith(`${pluginRoot}${path.sep}`), `${label} escapes its plugin root`);
	assert.ok(fs.existsSync(resolved), `${label} does not exist: ${value}`);
}

function componentPaths(value) {
	if (typeof value === 'string') return [value];
	if (Array.isArray(value)) {
		assert.ok(value.every(item => typeof item === 'string'), 'component path arrays may contain only strings');
		return value;
	}
	return [];
}

// Plugin roots, one level of group nesting deep: a dir under plugins/ with no
// manifest of its own is a plugin GROUP whose immediate children are plugins.
function pluginRoots(pluginsRoot) {
	const hasManifest = dir => fs.existsSync(path.join(dir, '.claude-plugin/plugin.json')) ||
		fs.existsSync(path.join(dir, '.codex-plugin/plugin.json'));
	const roots = [];
	for (const dir of directories(pluginsRoot)) {
		const base = path.join(pluginsRoot, dir);
		if (hasManifest(base)) { roots.push(base); continue; }
		for (const child of directories(base)) {
			const nested = path.join(base, child);
			if (hasManifest(nested)) roots.push(nested);
		}
	}
	return roots;
}

// A plugin dir named `bundle` inside a plugin group carries the GROUP's name: the
// bundle is the group's headline plugin, the dependency-only entry point that keeps
// the pre-split install command working (see plugins/pr-workflow/bundle).
function expectedManifestName(pluginRoot) {
	const base = path.basename(pluginRoot);
	return base === 'bundle' ? path.basename(path.dirname(pluginRoot)) : base;
}

function validateManifest(file) {
	const manifest = readJson(file);
	const pluginRoot = path.dirname(path.dirname(file));
	assert.match(manifest.name, /^[a-z0-9]+(?:-[a-z0-9]+)*$/, `${file}: name must be kebab-case`);
	assert.equal(manifest.name, expectedManifestName(pluginRoot), `${file}: name must match its directory`);
	assert.match(manifest.version, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, `${file}: version must be semver`);
	assert.equal(typeof manifest.description, 'string', `${file}: description is required`);
	assert.ok(manifest.description.trim(), `${file}: description cannot be empty`);

	for (const field of COMPONENT_FIELDS) {
		if (!(field in manifest)) continue;
		const inlineHooks = field === 'hooks' && manifest[field] && !Array.isArray(manifest[field]) && typeof manifest[field] === 'object';
		assert.ok(inlineHooks || typeof manifest[field] === 'string' || Array.isArray(manifest[field]),
			`${file}: ${field} must be a path, path array${field === 'hooks' ? ', or inline object' : ''}`);
		for (const value of componentPaths(manifest[field])) {
			assertSafeExistingPath(pluginRoot, value, `${file}: ${field}`);
		}
	}
}

function manifestPlugins(pluginsRoot, manifestDir) {
	const names = [];
	for (const dir of directories(pluginsRoot)) {
		const flat = path.join(pluginsRoot, dir, manifestDir, 'plugin.json');
		if (fs.existsSync(flat)) {
			names.push(readJson(flat).name);
			continue;
		}
		// No manifest at this level: treat as a group dir and scan one level deeper.
		for (const child of directories(path.join(pluginsRoot, dir))) {
			const nested = path.join(pluginsRoot, dir, child, manifestDir, 'plugin.json');
			if (fs.existsSync(nested)) names.push(readJson(nested).name);
		}
	}
	return names.sort();
}

function catalogEntries(file, root) {
	const catalog = readJson(file);
	assert.ok(Array.isArray(catalog.plugins), `${file}: plugins must be an array`);
	return catalog.plugins.map(entry => {
		const source = typeof entry.source === 'string' ? entry.source : entry.source?.path;
		assert.ok(source && source.startsWith('./plugins/'), `${file}: ${entry.name} source must live under ./plugins/`);
		const sourceDir = path.join(root, source);
		const manifestPath = ['.claude-plugin', '.codex-plugin']
			.map(d => path.join(sourceDir, d, 'plugin.json'))
			.find(p => fs.existsSync(p));
		assert.ok(manifestPath, `${file}: ${entry.name} source ${source} has no plugin manifest`);
		assert.equal(readJson(manifestPath).name, entry.name, `${file}: ${entry.name} has a mismatched manifest name at ${source}`);
		return { name: entry.name, source };
	});
}

function validateCatalogs(root) {
	const pluginsRoot = path.join(root, 'plugins');
	const legacy = catalogEntries(path.join(root, '.claude-plugin/marketplace.json'), root);
	const native = catalogEntries(path.join(root, '.agents/plugins/marketplace.json'), root);
	const legacyNames = legacy.map(entry => entry.name);
	const nativeNames = native.map(entry => entry.name);
	const legacySet = new Set(legacyNames);
	const nativeSet = new Set(nativeNames);
	assert.deepEqual([...legacySet].sort(), legacyNames.slice().sort(), 'legacy catalog contains duplicate names');
	assert.deepEqual([...nativeSet].sort(), nativeNames.slice().sort(), 'native catalog contains duplicate names');
	// The legacy catalog is exactly the Claude-manifest-bearing plugins.
	assert.deepEqual(legacyNames.slice().sort(), manifestPlugins(pluginsRoot, '.claude-plugin'),
		'legacy catalog must list exactly the .claude-plugin manifest-bearing plugins');
	// The Codex-native catalog is a GENERATED full-inventory catalog (ADR-002):
	// it must offer every legacy plugin — Codex reads their .claude-plugin
	// manifest by fallback — plus any native-only extras.
	for (const name of legacyNames) {
		assert.ok(nativeSet.has(name), `native catalog is missing legacy plugin ${name}`);
	}
	// A native-only extra (in the native catalog, absent from legacy) has no
	// Claude manifest to fall back to, so it must ship its own .codex-plugin one.
	const codexManifest = new Set(manifestPlugins(pluginsRoot, '.codex-plugin'));
	for (const name of nativeNames) {
		if (legacySet.has(name)) continue;
		assert.ok(codexManifest.has(name),
			`native-only catalog entry ${name} must ship a .codex-plugin/plugin.json`);
	}
	// Every native entry must resolve to an existing plugin directory.
	for (const entry of native) {
		assert.ok(fs.existsSync(path.join(root, entry.source)),
			`native catalog entry ${entry.name} has no plugin directory at ${entry.source}`);
	}
}

function pluginRootFor(pluginsRoot, file) {
	let dir = path.dirname(file);
	while (dir.length > pluginsRoot.length) {
		if (fs.existsSync(path.join(dir, '.claude-plugin', 'plugin.json')) ||
		    fs.existsSync(path.join(dir, '.codex-plugin', 'plugin.json'))) return dir;
		dir = path.dirname(dir);
	}
	return path.join(pluginsRoot, path.relative(pluginsRoot, file).split(path.sep)[0]);
}

function runtimeReferenceErrors(pluginsRoot) {
	const errors = [];
	for (const file of filesBelow(pluginsRoot)) {
		const relative = path.relative(pluginsRoot, file);
		if (!(file.endsWith('/SKILL.md') || file.endsWith('/hooks.json') || /(^|\/)commands\/[^/]+\.md$/.test(relative))) continue;
		const pluginRoot = pluginRootFor(pluginsRoot, file);
		const skillRoot = file.endsWith('/SKILL.md') ? path.dirname(file) : pluginRoot;
		const text = fs.readFileSync(file, 'utf8');
		const refs = text.matchAll(/(\$\{CLAUDE_PLUGIN_ROOT\}|\$PLUGIN_ROOT|\$GIT_TREE_ROOT|\$SKILL_DIR)\/([A-Za-z0-9._/-]+)/g);
		for (const match of refs) {
			const base = match[1] === '$SKILL_DIR' ? skillRoot : pluginRoot;
			const resolved = path.resolve(base, match[2]);
			if (!resolved.startsWith(`${base}${path.sep}`) || !fs.existsSync(resolved)) {
				errors.push(`${relative}: ${match[0]}`);
			}
		}
		for (const match of text.matchAll(/\]\((\.\.?\/[^\s)#]+)(?:#[^)]+)?\)/g)) {
			const resolved = path.resolve(path.dirname(file), match[1]);
			if (!resolved.startsWith(`${pluginsRoot}${path.sep}`) || !fs.existsSync(resolved)) {
				errors.push(`${relative}: ${match[1]}`);
			}
		}
	}
	return errors;
}

function frontmatterBoolean(text, key) {
	const frontmatter = text.match(/^---\s*\n([\s\S]*?)\n---(?:\s*\n|$)/)?.[1];
	if (!frontmatter) return undefined;
	const match = frontmatter.match(new RegExp(`^${key}:\\s*(true|false)\\s*$`, 'm'));
	return match ? match[1] === 'true' : undefined;
}

function openaiPolicyBoolean(text) {
	const policy = text.match(/^policy:\s*\n((?:[ \t]+.*\n?)*)/m)?.[1];
	const match = policy?.match(/^\s+allow_implicit_invocation:\s*(true|false)\s*$/m);
	return match ? match[1] === 'true' : undefined;
}

function invocationPolicyErrors(pluginsRoot) {
	const errors = [];
	for (const skillFile of filesBelow(pluginsRoot).filter(file => file.endsWith('/SKILL.md'))) {
		const metadataFile = path.join(path.dirname(skillFile), 'agents/openai.yaml');
		const disabled = frontmatterBoolean(fs.readFileSync(skillFile, 'utf8'), 'disable-model-invocation');
		// A skill that opts out of Claude model-invocation MUST mirror that in Codex.
		// A *missing* openai.yaml is the mirror silently absent — the exact gap that let
		// skills ship the flag with no Codex counterpart and a green suite
		// (claude-plugins-i7tv). A prior version `continue`d here, so it only ever fired
		// when the file existed and disagreed.
		if (!fs.existsSync(metadataFile)) {
			if (disabled === true) errors.push(path.relative(pluginsRoot, skillFile));
			continue;
		}
		const allowed = openaiPolicyBoolean(fs.readFileSync(metadataFile, 'utf8'));
		if (disabled !== undefined && allowed !== undefined && allowed === disabled) {
			errors.push(path.relative(pluginsRoot, skillFile));
		}
	}
	return errors;
}

function fixtureRoot() {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-compat-'));
	fs.mkdirSync(path.join(root, '.claude-plugin'), { recursive: true });
	fs.mkdirSync(path.join(root, '.agents/plugins'), { recursive: true });
	return root;
}

test('catalog guard requires full Codex inventory and native manifests for extras', () => {
	const root = fixtureRoot();
	try {
		for (const [name, manifestDir] of [['legacy-only', '.claude-plugin'], ['codex-only', '.codex-plugin']]) {
			const dir = path.join(root, 'plugins', name, manifestDir);
			fs.mkdirSync(dir, { recursive: true });
			// Catalog entries are now matched to their manifest's `name`, not to the
			// directory name, so the fixture manifests have to carry one.
			fs.writeFileSync(path.join(dir, 'plugin.json'), JSON.stringify({ name }));
		}
		fs.writeFileSync(path.join(root, '.claude-plugin/marketplace.json'), JSON.stringify({
			plugins: [{ name: 'legacy-only', source: './plugins/legacy-only' }],
		}));
		// Reject: the native catalog omits a legacy plugin (the 0way regression).
		fs.writeFileSync(path.join(root, '.agents/plugins/marketplace.json'), JSON.stringify({
			plugins: [{ name: 'codex-only', source: { path: './plugins/codex-only' } }],
		}));
		assert.throws(() => validateCatalogs(root));
		// Accept: native offers every legacy plugin plus a native-only extra that
		// carries its own .codex-plugin manifest.
		fs.writeFileSync(path.join(root, '.agents/plugins/marketplace.json'), JSON.stringify({
			plugins: [
				{ name: 'legacy-only', source: { path: './plugins/legacy-only' } },
				{ name: 'codex-only', source: { path: './plugins/codex-only' } },
			],
		}));
		assert.doesNotThrow(() => validateCatalogs(root));
		// Reject: a native-only extra with no .codex-plugin manifest to resolve.
		fs.mkdirSync(path.join(root, 'plugins/extra-no-manifest'), { recursive: true });
		fs.writeFileSync(path.join(root, '.agents/plugins/marketplace.json'), JSON.stringify({
			plugins: [
				{ name: 'legacy-only', source: { path: './plugins/legacy-only' } },
				{ name: 'codex-only', source: { path: './plugins/codex-only' } },
				{ name: 'extra-no-manifest', source: { path: './plugins/extra-no-manifest' } },
			],
		}));
		assert.throws(() => validateCatalogs(root));
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
});

test('marketplace catalogs match the current manifest-bearing plugin directories', () => {
	assert.doesNotThrow(() => validateCatalogs(REPO));
});

test('plugins that ship both manifests keep versions aligned', () => {
	// "Dual-published" is a manifest fact, not a catalog fact: every legacy plugin
	// now appears in the native catalog too (served by .claude-plugin fallback), so
	// the version-alignment obligation applies only to plugins that actually ship
	// BOTH a .claude-plugin and a .codex-plugin manifest. See docs/release.md §1.
	// Enumerated via pluginRoots so nested group-dir plugins are covered too — a flat
	// `plugins/*` scan would silently skip every child plugin instead of checking it.
	const dualPublished = new Map(pluginRoots(PLUGINS)
		.filter(root =>
			fs.existsSync(path.join(root, '.claude-plugin/plugin.json')) &&
			fs.existsSync(path.join(root, '.codex-plugin/plugin.json')),
		)
		.map(root => [readJson(path.join(root, '.claude-plugin/plugin.json')).name, root]));

	for (const [name, rationale] of DUAL_PUBLISHED_VERSION_EXCEPTIONS) {
		assert.ok(dualPublished.has(name), `version exception is not dual-published: ${name}`);
		assert.ok(rationale.trim().length >= 20, `version exception needs a concrete rationale: ${name}`);
	}

	for (const [name, root] of dualPublished) {
		const claudeVersion = readJson(path.join(root, '.claude-plugin/plugin.json')).version;
		const codexVersion = readJson(path.join(root, '.codex-plugin/plugin.json')).version;
		if (DUAL_PUBLISHED_VERSION_EXCEPTIONS.has(name)) {
			assert.notEqual(claudeVersion, codexVersion, `remove stale version exception for ${name}`);
			continue;
		}
		assert.equal(codexVersion, claudeVersion, `${name} shared release versions differ`);
	}
});

test('manifest guard rejects unsafe component paths and validates every manifest', () => {
	const root = fixtureRoot();
	try {
		const pluginRoot = path.join(root, 'bad-plugin');
		const manifestDir = path.join(pluginRoot, '.codex-plugin');
		fs.mkdirSync(manifestDir, { recursive: true });
		const file = path.join(manifestDir, 'plugin.json');
		fs.writeFileSync(file, JSON.stringify({
			name: 'bad-plugin', version: '1.0.0', description: 'fixture', skills: '../outside',
		}));
		assert.throws(() => validateManifest(file), /start with/);
		fs.mkdirSync(path.join(pluginRoot, 'skills'));
		fs.writeFileSync(file, JSON.stringify({
			name: 'bad-plugin', version: '1.0.0', description: 'fixture', skills: './skills/',
		}));
		assert.doesNotThrow(() => validateManifest(file));

		// A group's `bundle/` dir takes the GROUP's name, not "bundle" — one fixture per
		// direction, because the real tree only ever exercises the accepting one.
		const bundleDir = path.join(root, 'my-group', 'bundle', '.claude-plugin');
		fs.mkdirSync(bundleDir, { recursive: true });
		const bundleFile = path.join(bundleDir, 'plugin.json');
		const bundle = { version: '1.0.0', description: 'fixture' };
		fs.writeFileSync(bundleFile, JSON.stringify({ ...bundle, name: 'my-group' }));
		assert.doesNotThrow(() => validateManifest(bundleFile));
		fs.writeFileSync(bundleFile, JSON.stringify({ ...bundle, name: 'bundle' }));
		assert.throws(() => validateManifest(bundleFile), /name must match its directory/);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}

	const manifests = filesBelow(PLUGINS).filter(file => /\/\.(?:claude|codex)-plugin\/plugin\.json$/.test(file));
	assert.ok(manifests.length > 0);
	for (const file of manifests) assert.doesNotThrow(() => validateManifest(file));
});

test('runtime-path guard rejects missing files and validates shipped references', () => {
	const root = fixtureRoot();
	try {
		const skillRoot = path.join(root, 'plugins/example/skills/example');
		fs.mkdirSync(skillRoot, { recursive: true });
		fs.writeFileSync(path.join(skillRoot, 'SKILL.md'), 'run "$SKILL_DIR/scripts/missing.sh"\n');
		assert.deepEqual(runtimeReferenceErrors(path.join(root, 'plugins')), [
			'example/skills/example/SKILL.md: $SKILL_DIR/scripts/missing.sh',
		]);
		fs.mkdirSync(path.join(skillRoot, 'scripts'));
		fs.writeFileSync(path.join(skillRoot, 'scripts/missing.sh'), '');
		assert.deepEqual(runtimeReferenceErrors(path.join(root, 'plugins')), []);
		fs.appendFileSync(path.join(skillRoot, 'SKILL.md'), '[missing](./references/missing.md)\n');
		assert.deepEqual(runtimeReferenceErrors(path.join(root, 'plugins')), [
			'example/skills/example/SKILL.md: ./references/missing.md',
		]);
		fs.mkdirSync(path.join(skillRoot, 'references'));
		fs.writeFileSync(path.join(skillRoot, 'references/missing.md'), '');
		assert.deepEqual(runtimeReferenceErrors(path.join(root, 'plugins')), []);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
	assert.deepEqual(runtimeReferenceErrors(PLUGINS), []);
});

test('invocation-policy guard rejects Claude/Codex disagreement', () => {
	const root = fixtureRoot();
	try {
		const skillRoot = path.join(root, 'plugins/example/skills/example');
		fs.mkdirSync(path.join(skillRoot, 'agents'), { recursive: true });
		fs.writeFileSync(path.join(skillRoot, 'SKILL.md'), '---\nname: example\ndisable-model-invocation: true\n---\n');
		fs.writeFileSync(path.join(skillRoot, 'agents/openai.yaml'), 'interface:\n  display_name: Example\npolicy:\n  allow_implicit_invocation: true\n');
		assert.deepEqual(invocationPolicyErrors(path.join(root, 'plugins')), ['example/skills/example/SKILL.md']);
		fs.writeFileSync(path.join(skillRoot, 'agents/openai.yaml'), 'interface:\n  display_name: Example\npolicy:\n  allow_implicit_invocation: false\n');
		assert.deepEqual(invocationPolicyErrors(path.join(root, 'plugins')), []);
		// A missing openai.yaml under an explicit-only skill is a failure, not a skip
		// (claude-plugins-i7tv): remove the mirror and the guard must flag the skill.
		fs.rmSync(path.join(skillRoot, 'agents/openai.yaml'));
		assert.deepEqual(invocationPolicyErrors(path.join(root, 'plugins')), ['example/skills/example/SKILL.md']);
		// ...but a skill with no flag and no yaml is fine — the guard is opt-in.
		fs.writeFileSync(path.join(skillRoot, 'SKILL.md'), '---\nname: example\n---\n');
		assert.deepEqual(invocationPolicyErrors(path.join(root, 'plugins')), []);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
	assert.deepEqual(invocationPolicyErrors(PLUGINS), []);
});

test('explicit-only inventory has mirrored Codex policy and risk classification', () => {
	const report = collectExplicitInvocationPolicy(REPO);
	assert.equal(report.explicitOnly.length, 34);
	assert.equal(report.codexExplicitOnly.length, 34);
	assert.deepEqual(policyErrors(report), []);
});
