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
// Skills the proposal snapshot does not cover are listed under "No proposal yet" and left out
// of the budget figures — and out of the 1,536-cap check, which only ever measures proposed
// texts. Exits 1 on a proposed text over that cap, or on a proposal naming a skill absent
// from the tree. It is NOT the repo-wide budget guard.
//
// Reads:  plugins/*/skills/*/SKILL.md and plugins/*/*/skills/*/SKILL.md — the second
//         depth covers plugin groups, whose children are the plugins (see plugins/pr-workflow/).
//         (description, when_to_use, disable-model-invocation)
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

// The proposal set is a snapshot of one rewrite phase, so skills added afterwards
// are listed as unproposed rather than blocking the tables the doc is regenerated
// from. A proposal naming a skill that is not in the tree is drift the snapshot
// itself has to resolve, so that still fails.
const unproposed = skills.filter((s) => !(s.key in proposals));
const extra = Object.keys(proposals).filter((k) => !skills.some((s) => s.key === k));
if (extra.length) {
	console.error(`Proposals for unknown skills: ${extra.join(', ')}`);
	process.exit(1);
}
const proposed = skills.filter((s) => s.key in proposals);

function proposalFor(key) {
	const p = proposals[key];
	if (typeof p === 'string') return { description: p, when_to_use: '' };
	return { description: p.description ?? '', when_to_use: p.when_to_use ?? '' };
}

// A proposal the live tree has deliberately diverged from is history, not a target:
// measuring against it would report pending work that nobody intends to do. Its row
// reports the LIVE lengths (delta 0) and carries the reason.
function supersededReason(key) {
	const p = proposals[key];
	return (p && typeof p === 'object' && p.superseded) || '';
}
const superseded = Object.keys(proposals).filter(supersededReason);

let capViolations = 0;

function table(rows, label) {
	console.log(`\n## ${label} (${rows.length} skills)\n`);
	console.log('| plugin/skill | desc before | desc after | delta | wtu before | wtu after | CC combined after (cap 1536) |');
	console.log('|---|---:|---:|---:|---:|---:|---:|');
	const t = { descBefore: 0, descAfter: 0, wtuBefore: 0, wtuAfter: 0 };
	for (const s of rows.sort((a, b) => b.chars - a.chars)) {
		const p = proposalFor(s.key);
		const stale = !!supersededReason(s.key);
		const descAfter = stale ? s.chars : p.description.length;
		const wtuAfter = stale ? s.wtuChars : p.when_to_use.length;
		const ccTotal = descAfter + wtuAfter;
		let flag = stale ? ' _superseded_' : '';
		if (ccTotal > CLAUDE_PER_SKILL_CAP) { capViolations++; flag += ' **OVER CAP**'; }
		t.descBefore += s.chars;
		t.descAfter += descAfter;
		t.wtuBefore += s.wtuChars;
		t.wtuAfter += wtuAfter;
		console.log(
			`| ${s.key} | ${s.chars} | ${descAfter} | ${descAfter - s.chars} | ${s.wtuChars} | ${wtuAfter} | ${ccTotal}${flag} |`,
		);
	}
	console.log(
		`| **subtotal** | **${t.descBefore}** | **${t.descAfter}** | **${t.descAfter - t.descBefore}** | **${t.wtuBefore}** | **${t.wtuAfter}** | — |`,
	);
	return t;
}

const explicitOnly = proposed.filter((s) => s.dmi);
const implicit = proposed.filter((s) => !s.dmi);

const e = table(explicitOnly, 'Explicit-only (disable-model-invocation: true)');
const i = table(implicit, 'Implicitly invocable');

if (unproposed.length) {
	console.log(`\n## No proposal yet (${unproposed.length} skills)\n`);
	console.log('| plugin/skill | explicit-only | desc chars | wtu chars | CC combined (cap 1536) |');
	console.log('|---|:---:|---:|---:|---:|');
	let descTotal = 0;
	for (const s of [...unproposed].sort((a, b) => b.chars - a.chars)) {
		descTotal += s.chars;
		console.log(`| ${s.key} | ${s.dmi ? 'yes' : 'no'} | ${s.chars} | ${s.wtuChars} | ${s.chars + s.wtuChars} |`);
	}
	console.log(`| **subtotal** | — | **${descTotal}** | — | — |`);
	console.log(`\nThese carry ${descTotal} chars of Codex description budget that the figures below exclude.`);
}

const pct = (n, budget) => ((n / budget) * 100).toFixed(2);
const codexBefore = e.descBefore + i.descBefore;
const codexAfter = e.descAfter + i.descAfter;

console.log(`\n## Codex budget (description only, ${CODEX_BUDGET}-char global pool)\n`);
console.log(`Before: ${codexBefore} chars (${pct(codexBefore, CODEX_BUDGET)}%)`);
console.log(`After:  ${codexAfter} chars (${pct(codexAfter, CODEX_BUDGET)}%)`);
console.log(`  explicit-only: ${e.descBefore} -> ${e.descAfter}`);
console.log(`  implicit:      ${i.descBefore} -> ${i.descAfter}`);

console.log(`\n## Claude Code budget (description + when_to_use, ${CLAUDE_PER_SKILL_CAP}-char cap per skill)\n`);
const ccRows = proposed.map((s) => {
	const p = proposalFor(s.key);
	const stale = !!supersededReason(s.key);
	return {
		key: s.key,
		before: s.chars + s.wtuChars,
		after: stale ? s.chars + s.wtuChars : p.description.length + p.when_to_use.length,
	};
});
const ccBefore = ccRows.reduce((a, r) => a + r.before, 0);
const ccAfter = ccRows.reduce((a, r) => a + r.after, 0);
console.log(`Combined before: ${ccBefore} chars; after: ${ccAfter} chars (delta ${ccAfter - ccBefore})`);
const worst = [...ccRows].sort((a, b) => b.after - a.after)[0];
console.log(`Largest per-skill combined after: ${worst.key} at ${worst.after} (${pct(worst.after, CLAUDE_PER_SKILL_CAP)}% of the ${CLAUDE_PER_SKILL_CAP} cap)`);
console.log(`Proposed skills over the ${CLAUDE_PER_SKILL_CAP} cap: ${capViolations} of ${proposed.length} measured; the ${unproposed.length} unproposed skills are not cap-checked`);

const withWtu = proposed.filter((s) => proposalFor(s.key).when_to_use.length > 0);
console.log(`\nProposals carrying a when_to_use: ${withWtu.length}`);

if (superseded.length) {
	console.log(`\nSuperseded proposals (measured against the live text, not the proposal): ${superseded.length}`);
	for (const k of superseded) console.log(`  ${k}: ${supersededReason(k)}`);
}

const over = proposed
	.map((s) => [s.key, supersededReason(s.key) ? s.chars : proposalFor(s.key).description.length])
	.filter(([, n]) => n > 200)
	.sort((a, b) => b[1] - a[1]);
console.log(`\nProposed descriptions over 200 chars: ${over.length}`);
for (const [k, n] of over) console.log(`  ${k}: ${n}`);

process.exit(capViolations > 0 ? 1 : 0);
