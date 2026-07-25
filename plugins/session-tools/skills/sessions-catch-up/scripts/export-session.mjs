#!/usr/bin/env node
// =============================================================================
// export-session.mjs — read a Claude Code session transcript out of a session.
// By Justin Sternberg <me@jtsternberg.com>
//
// The `claude export <session-id>` that Claude Code does not ship. `/export` is
// a TUI-only local command: `claude -p "/export <path>"` answers "/export isn't
// available in this environment" and writes nothing. The only other way to drive
// it is typing into a live REPL (as graveyard does), which needs the session
// alive in a pane, appends a turn to the target, and takes up to 30s.
//
// This reads the JSONL directly instead: works on dead sessions, costs zero
// tokens, mutates nothing, returns in milliseconds.
//
// Usage:
//   export-session.mjs <session-id|prefix|slug|title> [options]
//
//   --format md|json|text|digest   output shape (default: digest)
//   --window N                     turns kept verbatim in a digest (default 12)
//   --max-chars N                  digest budget ceiling (default 40000)
//   --truncate N                   per-turn char cap in a digest (default 2000)
//   --fast                         smaller window, skip live beads resolution
//   --no-beads                     skip `bd show` resolution
//   --out PATH                     also write to PATH
//   --cwd PATH                     cwd used to disambiguate names (default: $PWD)
//   --list                         list all sessions (id, idle, cwd, slug)
// =============================================================================

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { parseTranscript, deriveSignals, humanIdle } from './lib/transcript.mjs';
import { resolve, loadIndex, rankCandidates, AmbiguousTarget, NoMatch } from './lib/session-index.mjs';
import { formatDigest, formatMd, formatText, formatJson } from './lib/format.mjs';

function parseArgs(argv) {
	const o = { format: 'digest', beads: true, fast: false };
	const rest = [];
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === '--format') o.format = argv[++i];
		else if (a === '--window') o.window = parseInt(argv[++i], 10);
		else if (a === '--max-chars') o.maxChars = parseInt(argv[++i], 10);
		else if (a === '--truncate') o.truncAt = parseInt(argv[++i], 10);
		else if (a === '--out') o.out = argv[++i];
		else if (a === '--cwd') o.cwd = argv[++i];
		else if (a === '--fast') o.fast = true;
		else if (a === '--compaction-full') o.compactionCap = Infinity;
		else if (a === '--no-beads') o.beads = false;
		else if (a === '--list') o.list = true;
		else if (a === '-h' || a === '--help') o.help = true;
		else if (a.startsWith('--')) { /* ignore unknown */ }
		else rest.push(a);
	}
	o.target = rest[0];
	return o;
}

function die(msg, code = 1) {
	process.stderr.write(msg.endsWith('\n') ? msg : msg + '\n');
	process.exit(code);
}

function showCandidates(target, candidates) {
	const lines = [`'${target}' is ambiguous — ${candidates.length} matches. Narrow it or pass a full session id:`, ''];
	for (const c of candidates.slice(0, 15)) {
		lines.push(`  ${c.id}  ${humanIdle(Date.now() - c.mtimeMs).padEnd(9)}  ${(c.slug || c.title || '').slice(0, 32).padEnd(32)}  ${c.cwd || ''}`);
	}
	if (candidates.length > 15) lines.push(`  …and ${candidates.length - 15} more`);
	die(lines.join('\n'));
}

/**
 * Resolve bead ids to live status. This is the point of extracting them: a
 * two-day-old transcript says what the beads WERE, `bd show` says what they ARE.
 */
function resolveBeads(ids) {
	const out = {};
	if (!ids.length) return out;
	try { execFileSync('bd', ['--version'], { stdio: 'ignore', timeout: 3000 }); } catch { return out; }
	for (const id of ids.slice(0, 10)) {
		try {
			const raw = execFileSync('bd', ['show', id, '--json'], { encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'] });
			const parsed = JSON.parse(raw);
			const rec = Array.isArray(parsed) ? parsed[0] : (parsed.issue || parsed);
			if (rec && rec.id) out[id] = { title: rec.title || '', status: rec.status || '?' };
		} catch { /* unknown id or bd unavailable — drop it */ }
	}
	return out;
}

function listSessions(cwd) {
	const idx = rankCandidates(loadIndex(), cwd);
	const lines = idx.map(c =>
		`${c.id}  ${humanIdle(Date.now() - c.mtimeMs).padEnd(9)}  ${(c.slug || c.title || '').slice(0, 34).padEnd(34)}  ${c.cwd || ''}`);
	process.stdout.write(lines.join('\n') + '\n');
}

const HELP = `export-session.mjs <session-id|prefix|slug|title> [--format md|json|text|digest]
                          [--window N] [--max-chars N] [--truncate N]
                          [--fast] [--no-beads] [--out PATH] [--cwd PATH] [--list]`;

function main() {
	const o = parseArgs(process.argv.slice(2));
	if (o.help) { process.stdout.write(HELP + '\n'); return; }
	const cwd = o.cwd || process.cwd();
	if (o.list) return listSessions(cwd);
	if (!o.target) die(HELP);

	let file;
	try {
		({ file } = resolve(o.target, { cwd }));
	} catch (err) {
		if (err instanceof AmbiguousTarget) showCandidates(err.target, err.candidates);
		if (err instanceof NoMatch) die(`No session matches '${o.target}'.\nTry: export-session.mjs --list`);
		throw err;
	}

	const parsed = parseTranscript(file);
	const signals = deriveSignals(parsed.entries, parsed.subagents);
	const data = { meta: parsed.meta, entries: parsed.entries, signals };

	const resolvedBeads = (o.beads && !o.fast) ? resolveBeads(signals.beadIds) : {};

	let out;
	switch (o.format) {
		case 'json': out = formatJson({ ...data, resolvedBeads }); break;
		case 'md': out = formatMd(data); break;
		case 'text': out = formatText(data); break;
		case 'digest':
		default:
			out = formatDigest(data, {
				window: o.window ?? (o.fast ? 8 : 12),
				maxChars: o.maxChars,
				truncAt: o.truncAt ?? (o.fast ? 1200 : 2000),
				compactionCap: o.compactionCap ?? (o.fast ? 4000 : 8000),
				resolvedBeads,
			});
	}

	if (o.out) {
		fs.mkdirSync(path.dirname(o.out), { recursive: true });
		fs.writeFileSync(o.out, out);
		process.stderr.write(`wrote ${o.out}\n`);
	}
	process.stdout.write(out.endsWith('\n') ? out : out + '\n');
}

main();
