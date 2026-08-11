#!/usr/bin/env node
/**
 * Inventory names which Codex can discover locally. This is intentionally a
 * read-only maintainer report: it reads public SKILL.md frontmatter and public
 * marketplace/plugin manifests, never Codex credentials or configuration.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
const value = flag => {
	const index = args.indexOf(flag);
	if (index === -1 || !args[index + 1]) return undefined;
	return args[index + 1];
};
const has = flag => args.includes(flag);
if (has('--help')) {
	console.log(`Usage: node scripts/inventory-codex-namespaces.mjs [options]

Options:
  --workspace DIR             Start of the repository .agents/skills walk (default: cwd)
  --repo-root DIR             End of that walk (default: git root or workspace)
  --home DIR                  Home directory to inspect (default: OS home)
  --codex-home DIR            Codex home (default: CODEX_HOME or HOME/.codex)
  --admin-skills DIR          Administrator skills directory (default: /etc/codex/skills)
  --plugin-list-json FILE     Saved codex plugin list --json output
  --marketplaces-json FILE    Saved codex plugin marketplace list --json output
  --skill-root LABEL:DIR      Add an explicit standalone skill root (repeatable)
  --output FILE               Write Markdown to FILE instead of stdout

Without the two JSON options the script calls the read-only Codex list commands.
`);
	process.exit(0);
}

function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function exists(dir) { try { return fs.statSync(dir).isDirectory(); } catch { return false; } }
function fileExists(file) { try { return fs.statSync(file).isFile(); } catch { return false; } }
function unique(values) { return [...new Set(values)]; }
function shellJson(command, commandArgs) {
	return JSON.parse(execFileSync(command, commandArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
}
function displayPath(file, home, workspace) {
	if (file === workspace || file.startsWith(`${workspace}${path.sep}`)) return `<WORKSPACE>${file.slice(workspace.length)}`;
	if (file === home || file.startsWith(`${home}${path.sep}`)) return `<HOME>${file.slice(home.length)}`;
	return '<EXTERNAL>';
}
function skillName(file) {
	const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
	if (lines[0] !== '---') return undefined;
	for (let i = 1; i < lines.length && lines[i] !== '---'; i++) {
		const match = lines[i].match(/^name:\s*(?:['\"]([^'\"]+)['\"]|([^\s#]+))\s*(?:#.*)?$/);
		if (match) return match[1] || match[2];
	}
	return undefined;
}
function skillFiles(root) {
	if (!exists(root)) return [];
	return fs.readdirSync(root, { withFileTypes: true }).flatMap(entry => {
		if (!entry.isDirectory() && !entry.isSymbolicLink()) return [];
		const file = path.join(root, entry.name, 'SKILL.md');
		return fileExists(file) ? [file] : [];
	});
}
function nestedSkillFiles(pluginRoot) {
	return skillFiles(path.join(pluginRoot, 'skills'));
}
function workspaceSkillRoots(workspace, repoRoot) {
	const roots = [];
	let current = path.resolve(workspace);
	const end = path.resolve(repoRoot);
	for (;;) {
		roots.push(path.join(current, '.agents', 'skills'));
		if (current === end || current === path.dirname(current)) break;
		current = path.dirname(current);
	}
	return roots;
}
function parseRoot(value, flag) {
	const split = value.indexOf(':');
	if (split <= 0 || split === value.length - 1) throw new Error(`${flag} must use LABEL:DIR`);
	return { label: value.slice(0, split), root: value.slice(split + 1) };
}
function manifestPluginNames(root) {
	const catalogFiles = [
		path.join(root, '.agents', 'plugins', 'marketplace.json'),
		path.join(root, '.claude-plugin', 'marketplace.json'),
		path.join(root, '.codex-plugin', 'marketplace.json'),
		path.join(root, 'marketplace.json'),
	].filter(fileExists);
	for (const file of catalogFiles) {
		const parsed = readJson(file);
		if (Array.isArray(parsed.plugins)) {
			return { names: parsed.plugins.map(plugin => plugin.name).filter(name => typeof name === 'string'), method: path.relative(root, file) || path.basename(file) };
		}
	}
	const pluginsDir = path.join(root, 'plugins');
	if (!exists(pluginsDir)) return { names: [], method: 'unavailable' };
	const names = fs.readdirSync(pluginsDir, { withFileTypes: true }).flatMap(entry => {
		if (!entry.isDirectory()) return [];
		for (const manifest of ['.codex-plugin/plugin.json', '.claude-plugin/plugin.json']) {
			const file = path.join(pluginsDir, entry.name, manifest);
			if (fileExists(file)) {
				const name = readJson(file).name;
				return typeof name === 'string' ? [name] : [];
			}
		}
		return [];
	});
	return { names, method: names.length ? 'plugin manifests' : 'unavailable' };
}
function collisionDisposition(entries) {
	const kinds = unique(entries.map(entry => entry.kind));
	if (kinds.every(kind => kind === 'plugin')) return 'accept: Codex attributes plugin entries; use name@marketplace when installing';
	if (kinds.every(kind => kind === 'system')) return 'accept: system names are reserved by Codex';
	if (kinds.every(kind => kind === 'standalone')) return 'consolidate: keep one documented standalone root (.agents/skills) and remove or rename the other local copy';
	return 'accept: plugin/system entries are attributed; consolidate duplicate standalone copies before relying on an unqualified invocation';
}
function markdownTable(rows) {
	if (!rows.length) return '_None._\n';
	return ['| Name | Sources | Disposition |', '| --- | --- | --- |', ...rows.map(row => `| \`${row.name}\` | ${row.sources} | ${row.disposition} |`)].join('\n');
}

const workspace = path.resolve(value('--workspace') || process.cwd());
let repoRoot = value('--repo-root');
if (!repoRoot) {
	try { repoRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: workspace, encoding: 'utf8' }).trim(); }
	catch { repoRoot = workspace; }
}
repoRoot = path.resolve(repoRoot);
const home = path.resolve(value('--home') || os.homedir());
const codexHome = path.resolve(value('--codex-home') || process.env.CODEX_HOME || path.join(home, '.codex'));
const adminSkills = path.resolve(value('--admin-skills') || '/etc/codex/skills');
const pluginList = value('--plugin-list-json') ? readJson(value('--plugin-list-json')) : shellJson('codex', ['plugin', 'list', '--json']);
const marketplaces = value('--marketplaces-json') ? readJson(value('--marketplaces-json')) : shellJson('codex', ['plugin', 'marketplace', 'list', '--json']);

const roots = [
	...workspaceSkillRoots(workspace, repoRoot).map(root => ({ label: 'workspace .agents/skills', root, kind: 'standalone' })),
	{ label: 'user .agents/skills', root: path.join(home, '.agents', 'skills'), kind: 'standalone' },
	{ label: 'user .codex/skills', root: path.join(codexHome, 'skills'), kind: 'standalone', exclude: '.system' },
	{ label: 'Codex system skills', root: path.join(codexHome, 'skills', '.system'), kind: 'system' },
	{ label: 'administrator skills', root: adminSkills, kind: 'standalone' },
];
// Parse repeatable --skill-root arguments without making an environment-specific default.
const extraRoots = [];
for (let i = 0; i < args.length; i++) if (args[i] === '--skill-root') extraRoots.push(parseRoot(args[++i], '--skill-root'));
roots.push(...extraRoots.map(entry => ({ ...entry, kind: 'standalone' })));

const skills = [];
for (const source of roots) {
	if (!exists(source.root)) continue;
	for (const file of skillFiles(source.root)) {
		if (source.exclude && path.basename(path.dirname(file)) === source.exclude) continue;
		const name = skillName(file);
		if (name) skills.push({ name, source: source.label, kind: source.kind, file });
	}
}
const enabled = Array.isArray(pluginList.installed) ? pluginList.installed.filter(plugin => plugin.enabled) : [];
for (const plugin of enabled) {
	if (!plugin.name || !plugin.marketplaceName || !plugin.version) continue;
	const root = path.join(codexHome, 'plugins', 'cache', plugin.marketplaceName, plugin.name, String(plugin.version));
	for (const file of nestedSkillFiles(root)) {
		const name = skillName(file);
		if (name) skills.push({ name, source: `${plugin.name}@${plugin.marketplaceName}`, kind: 'plugin', file });
	}
}
const skillGroups = new Map();
for (const entry of skills) skillGroups.set(entry.name, [...(skillGroups.get(entry.name) || []), entry]);
const skillCollisions = [...skillGroups].filter(([, entries]) => entries.length > 1).map(([name, entries]) => ({
	name,
	sources: unique(entries.map(entry => entry.source)).sort().join('<br>'),
	disposition: collisionDisposition(entries),
	entries,
})).sort((a, b) => a.name.localeCompare(b.name));

const marketplaceEntries = Array.isArray(marketplaces.marketplaces) ? marketplaces.marketplaces : [];
const plugins = [];
const catalogMethods = [];
for (const marketplace of marketplaceEntries) {
	if (!marketplace.name || !marketplace.root) continue;
	const { names, method } = manifestPluginNames(marketplace.root);
	catalogMethods.push({ name: marketplace.name, method, count: names.length });
	for (const name of names) plugins.push({ name, marketplace: marketplace.name });
}
const pluginGroups = new Map();
for (const plugin of plugins) pluginGroups.set(plugin.name, [...(pluginGroups.get(plugin.name) || []), plugin]);
const pluginCollisions = [...pluginGroups].filter(([, entries]) => entries.length > 1).map(([name, entries]) => ({
	name,
	sources: unique(entries.map(entry => entry.marketplace)).sort().join('<br>'),
	disposition: 'accept: marketplace-qualified plugin IDs are unambiguous; keep the marketplace names',
})).sort((a, b) => a.name.localeCompare(b.name));

const sourceCounts = roots.map(source => ({
	label: source.label,
	count: skills.filter(skill => skill.source === source.label).length,
	root: displayPath(source.root, home, workspace),
}));
sourceCounts.push({ label: 'enabled plugin cache', count: skills.filter(skill => skill.kind === 'plugin').length, root: '<CODEX_HOME>/plugins/cache (enabled plugins only)' });
const missingCatalogs = catalogMethods.filter(item => item.method === 'unavailable');
const report = `# Codex namespace inventory

Generated by \`node scripts/inventory-codex-namespaces.mjs\`. It is a read-only
snapshot of public skill frontmatter and public marketplace/plugin manifests.
It deliberately does not read credentials, tokens, or general Codex config.

## Discovery sources

The generator checks six live source types: workspace/ancestor
\`.agents/skills\`, user \`.agents/skills\`, user \`.codex/skills\`, Codex system
skills, administrator skills, and enabled plugin caches. An explicit
\`--skill-root\` adds a test or exceptional standalone source. Plugin caches are
selected from enabled \`codex plugin list\` records, so stale cached versions do
not inflate the live inventory.

| Source | Skills | Root |
| --- | ---: | --- |
${sourceCounts.map(item => `| ${item.label} | ${item.count} | \`${item.root}\` |`).join('\n')}

Enabled plugins: ${enabled.length}. Discovered skills: ${skills.length}. Skill-name collisions: ${skillCollisions.length}.

## Skill-name collisions

${markdownTable(skillCollisions)}
Plugin entries have a source label in the Codex selector; that makes a
plugin-vs-plugin collision an attribution concern, not a blind choice. The
unqualified risk is duplicate standalone copies. The disposition above therefore
consolidates local copies under the documented \`.agents/skills\` root without
renaming repository skills or changing an installed configuration.

## Marketplace plugin-name collisions

Configured marketplaces: ${marketplaceEntries.length}. Public catalog entries read: ${plugins.length}. Plugin-name collisions: ${pluginCollisions.length}.

${markdownTable(pluginCollisions)}
${missingCatalogs.length ? `Catalog metadata was unavailable for: ${missingCatalogs.map(item => `\`${item.name}\``).join(', ')}. The generator still records the configured marketplace, but cannot claim an exhaustive catalog count for it.\n` : ''}
## Marketplace-name decision

Keep \`jtsternberg\`. It is a distinctive publisher identity, already embedded in
published \`plugin@marketplace\` references, and it does not collide with another
configured marketplace. The \`codex\` plugin-name collision is safely expressed
as \`codex@jtsternberg\` versus \`codex@openai-codex\`; it is not evidence that
the marketplace should be renamed.

## Marketplace catalog coverage

| Marketplace | Entries | Source |
| --- | ---: | --- |
${catalogMethods.sort((a, b) => a.name.localeCompare(b.name)).map(item => `| ${item.name} | ${item.count} | ${item.method} |`).join('\n')}
`;
const renderedReport = `${report.trimEnd()}\n`;
const output = value('--output');
if (output) fs.writeFileSync(output, renderedReport);
else process.stdout.write(renderedReport);
