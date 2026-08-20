#!/usr/bin/env node
// Compare current SKILL.md frontmatter against proposed rewrites, measuring BOTH budgets:
//   - Codex:       description only, pooled across all installed skills (~8,000-char global budget)
//   - Claude Code: description + when_to_use per skill (1,536-char per-skill cap, shared by both fields)
//
// Codex 0.145.0 was verified to ignore when_to_use entirely (no matching effect, no warning),
// while Claude Code appends when_to_use to the description as additional invocation context.
// So trigger vocabulary moved from description -> when_to_use stays matchable in Claude Code
// and stops costing Codex budget.
//
// Usage:
//   node scripts/compare-skill-descriptions.mjs                # tables + totals for both budgets
//   node scripts/compare-skill-descriptions.mjs --dump-current # emit current state as JSON
//
// Reads:  plugins/*/skills/*/SKILL.md (description, when_to_use, disable-model-invocation)
//         docs/codex/proposed-descriptions.json — keyed by "plugin/skill"; each value is either
//         a string (description only) or { "description": ..., "when_to_use": ... }.
//
// Frontmatter parsing mirrors scripts/measure-skill-descriptions.sh: plain scalars,
// single/double-quoted scalars, and YAML folded (>) / literal (|) block scalars.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const CODEX_BUDGET = 8000;
const CLAUDE_PER_SKILL_CAP = 1536;

function parseScalar(value) {
	if (/^".*"$/.test(value)) {
		return value.slice(1, -1).replace(/\\(.)/g, (_, c) => ({ n: '\n', r: '\r', t: '\t' }[c] ?? c));
	}
	if (/^'.*'$/.test(value)) {
		return value.slice(1, -1).replace(/''/g, "'");
	}
	return value;
}

// Generic YAML-subset frontmatter parser for top-level string fields.
function parseFrontmatter(file) {
	const lines = readFileSync(file, 'utf8').split('\n');
	const fields = {};
	if (lines[0] !== '---') return fields;
	let collecting = null; // { key, style, foldedBreak }
	for (let i = 1; i < lines.length; i++) {
		const line = lines[i];
		if (line === '---') break;
		if (collecting) {
			if (/^\s/.test(line) || line === '') {
				const value = line.replace(/^\s+/, '');
				const k = collecting.key;
				if (collecting.style === '|') {
					if (fields[k] !== '') fields[k] += '\n';
					fields[k] += value;
				} else if (value === '') {
					if (fields[k] !== '') fields[k] += '\n';
					collecting.foldedBreak = true;
				} else {
					if (fields[k] !== '' && !collecting.foldedBreak) fields[k] += ' ';
					fields[k] += value;
					collecting.foldedBreak = false;
				}
				continue;
			}
			collecting = null;
		}
		const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
		if (!kv) continue;
		const [, key, rawValue] = kv;
		const value = rawValue.trim();
		if (/^[>|][+-]?$/.test(value)) {
			fields[key] = '';
			collecting = { key, style: value[0], foldedBreak: false };
			continue;
		}
		fields[key] = parseScalar(value);
	}
	// Trim trailing newlines the same way YAML block-scalar clipping does.
	for (const k of Object.keys(fields)) fields[k] = fields[k].replace(/\n+$/, '');
	return fields;
}

// A dir under plugins/ with no `skills/` and no manifest is a plugin GROUP: its
// immediate children are the plugins (see plugins/pr-workflow/).
function skillRoots(pluginsDir) {
	const roots = [];
	for (const dir of readdirSync(pluginsDir).sort()) {
		const base = join(pluginsDir, dir);
		if (!statSync(base).isDirectory()) continue;
		if (existsSync(join(base, 'skills'))) { roots.push({ label: dir, dir: join(base, 'skills') }); continue; }
		if (existsSync(join(base, '.claude-plugin')) || existsSync(join(base, '.codex-plugin'))) continue; // plugin without skills
		for (const child of readdirSync(base).sort()) {
			const nested = join(base, child, 'skills');
			if (existsSync(nested)) roots.push({ label: `${dir}/${child}`, dir: nested });
		}
	}
	return roots;
}

function collectSkills() {
	const skills = [];
	const pluginsDir = join(repoRoot, 'plugins');
	for (const { label: plugin, dir: skillsDir } of skillRoots(pluginsDir)) {
		for (const skill of readdirSync(skillsDir).sort()) {
			const skillFile = join(skillsDir, skill, 'SKILL.md');
			if (!existsSync(skillFile)) continue;
			const f = parseFrontmatter(skillFile);
			const description = f.description ?? '';
			const whenToUse = f.when_to_use ?? '';
			skills.push({
				key: `${plugin}/${skill}`,
				plugin,
				skill,
				dmi: f['disable-model-invocation'] === 'true',
				description,
				when_to_use: whenToUse,
				chars: description.length,
				wtuChars: whenToUse.length,
			});
		}
	}
	return skills;
}

const skills = collectSkills();

if (process.argv.includes('--dump-current')) {
	console.log(JSON.stringify(skills, null, 2));
	process.exit(0);
}

const proposalsFile = join(repoRoot, 'docs', 'codex', 'proposed-descriptions.json');
const proposals = JSON.parse(readFileSync(proposalsFile, 'utf8'));

const missing = skills.filter((s) => !(s.key in proposals));
const extra = Object.keys(proposals).filter((k) => !skills.some((s) => s.key === k));
if (missing.length || extra.length) {
	if (missing.length) console.error(`Missing proposals for: ${missing.map((s) => s.key).join(', ')}`);
	if (extra.length) console.error(`Proposals for unknown skills: ${extra.join(', ')}`);
	process.exit(1);
}

function proposalFor(key) {
	const p = proposals[key];
	if (typeof p === 'string') return { description: p, when_to_use: '' };
	return { description: p.description ?? '', when_to_use: p.when_to_use ?? '' };
}

let capViolations = 0;

function table(rows, label) {
	console.log(`\n## ${label} (${rows.length} skills)\n`);
	console.log('| plugin/skill | desc before | desc after | delta | wtu before | wtu after | CC combined after (cap 1536) |');
	console.log('|---|---:|---:|---:|---:|---:|---:|');
	const t = { descBefore: 0, descAfter: 0, wtuBefore: 0, wtuAfter: 0 };
	for (const s of rows.sort((a, b) => b.chars - a.chars)) {
		const p = proposalFor(s.key);
		const ccTotal = p.description.length + p.when_to_use.length;
		const flag = ccTotal > CLAUDE_PER_SKILL_CAP ? ' **OVER CAP**' : '';
		if (ccTotal > CLAUDE_PER_SKILL_CAP) capViolations++;
		t.descBefore += s.chars;
		t.descAfter += p.description.length;
		t.wtuBefore += s.wtuChars;
		t.wtuAfter += p.when_to_use.length;
		console.log(
			`| ${s.key} | ${s.chars} | ${p.description.length} | ${p.description.length - s.chars} | ${s.wtuChars} | ${p.when_to_use.length} | ${ccTotal}${flag} |`,
		);
	}
	console.log(
		`| **subtotal** | **${t.descBefore}** | **${t.descAfter}** | **${t.descAfter - t.descBefore}** | **${t.wtuBefore}** | **${t.wtuAfter}** | — |`,
	);
	return t;
}

const explicitOnly = skills.filter((s) => s.dmi);
const implicit = skills.filter((s) => !s.dmi);

const e = table(explicitOnly, 'Explicit-only (disable-model-invocation: true)');
const i = table(implicit, 'Implicitly invocable');

const pct = (n, budget) => ((n / budget) * 100).toFixed(2);
const codexBefore = e.descBefore + i.descBefore;
const codexAfter = e.descAfter + i.descAfter;

console.log(`\n## Codex budget (description only, ${CODEX_BUDGET}-char global pool)\n`);
console.log(`Before: ${codexBefore} chars (${pct(codexBefore, CODEX_BUDGET)}%)`);
console.log(`After:  ${codexAfter} chars (${pct(codexAfter, CODEX_BUDGET)}%)`);
console.log(`  explicit-only: ${e.descBefore} -> ${e.descAfter}`);
console.log(`  implicit:      ${i.descBefore} -> ${i.descAfter}`);

console.log(`\n## Claude Code budget (description + when_to_use, ${CLAUDE_PER_SKILL_CAP}-char cap per skill)\n`);
const ccRows = skills.map((s) => {
	const p = proposalFor(s.key);
	return {
		key: s.key,
		before: s.chars + s.wtuChars,
		after: p.description.length + p.when_to_use.length,
	};
});
const ccBefore = ccRows.reduce((a, r) => a + r.before, 0);
const ccAfter = ccRows.reduce((a, r) => a + r.after, 0);
console.log(`Combined before: ${ccBefore} chars; after: ${ccAfter} chars (delta ${ccAfter - ccBefore})`);
const worst = [...ccRows].sort((a, b) => b.after - a.after)[0];
console.log(`Largest per-skill combined after: ${worst.key} at ${worst.after} (${pct(worst.after, CLAUDE_PER_SKILL_CAP)}% of the ${CLAUDE_PER_SKILL_CAP} cap)`);
console.log(`Skills over the ${CLAUDE_PER_SKILL_CAP} cap: ${capViolations}`);

const withWtu = skills.filter((s) => proposalFor(s.key).when_to_use.length > 0);
console.log(`\nProposals carrying a when_to_use: ${withWtu.length}`);

const over = skills
	.map((s) => [s.key, proposalFor(s.key).description.length])
	.filter(([, n]) => n > 200)
	.sort((a, b) => b[1] - a[1]);
console.log(`\nProposed descriptions over 200 chars: ${over.length}`);
for (const [k, n] of over) console.log(`  ${k}: ${n}`);

process.exit(capViolations > 0 ? 1 : 0);
