// =============================================================================
// session-index.mjs — resolve a session id, id-prefix, slug, or title to its
// transcript file.
//
// Two tiers, deliberately:
//   1. ID / ID-prefix  → directory scan only. ~67 readdirs, no file reads, no
//      index build. This is the hot path and must stay instant.
//   2. name / slug / title → needs a cached index, since slugs and titles live
//      INSIDE the files. Built by reading only the head + tail of each file.
//
// Filenames ARE the session id and are unique across every project dir
// (verified: no basename appears in two dirs), so an id resolves unambiguously.
// The encoded-cwd dir name is lossy (every non-alphanumeric collapses to '-'),
// so cwd is always read OUT of the transcript, never decoded from the dir name.
// =============================================================================

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { PROJECTS_ROOT } from './transcript.mjs';

const INDEX_PATH = path.join(os.homedir(), '.claude', '.catchup-index.json');
const EDGE_BYTES = 32 * 1024;

function projectDirs() {
	try {
		return fs.readdirSync(PROJECTS_ROOT, { withFileTypes: true })
			.filter(d => d.isDirectory())
			.map(d => path.join(PROJECTS_ROOT, d.name));
	} catch { return []; }
}

/** Session transcripts only: <projects>/<dir>/<id>.jsonl. Never subagent files. */
function sessionFilesIn(dir) {
	try {
		return fs.readdirSync(dir, { withFileTypes: true })
			.filter(d => d.isFile() && d.name.endsWith('.jsonl') && d.name !== 'history.jsonl')
			.map(d => path.join(dir, d.name));
	} catch { return []; }
}

export function allSessionFiles() {
	return projectDirs().flatMap(sessionFilesIn);
}

/** Read the first and last EDGE_BYTES of a file, returning complete lines only. */
function edgeLines(file, size) {
	const fd = fs.openSync(file, 'r');
	try {
		const headLen = Math.min(EDGE_BYTES, size);
		const head = Buffer.alloc(headLen);
		fs.readSync(fd, head, 0, headLen, 0);
		const headStr = head.toString('utf8');

		let tailStr = '';
		if (size > EDGE_BYTES) {
			const tailLen = Math.min(EDGE_BYTES, size);
			const tail = Buffer.alloc(tailLen);
			fs.readSync(fd, tail, 0, tailLen, size - tailLen);
			tailStr = tail.toString('utf8');
		}

		const headComplete = headStr.slice(0, Math.max(0, headStr.lastIndexOf('\n')));
		const tailComplete = tailStr.slice(tailStr.indexOf('\n') + 1);
		return [...headComplete.split('\n'), ...tailComplete.split('\n')].filter(l => l.trim());
	} finally { fs.closeSync(fd); }
}

/** Cheap per-file descriptor: identity + slug + title, without a full parse. */
export function describeFile(file) {
	let st;
	try { st = fs.statSync(file); } catch { return null; }
	const rec = {
		id: path.basename(file, '.jsonl'),
		file, cwd: null, gitBranch: null, slug: null, title: null,
		mtimeMs: st.mtimeMs, sizeBytes: st.size,
	};
	let lines = [];
	try { lines = edgeLines(file, st.size); } catch { return rec; }
	for (const line of lines) {
		let o;
		try { o = JSON.parse(line); } catch { continue; }
		if (!o || typeof o !== 'object') continue;
		if (!rec.cwd && o.cwd) rec.cwd = o.cwd;
		if (o.gitBranch) rec.gitBranch = o.gitBranch;
		if (o.slug) rec.slug = o.slug;
		if (o.type === 'custom-title' && o.title) rec.title = o.title;
		if (o.type === 'ai-title' && o.title && !rec.title) rec.title = o.title;
	}
	return rec;
}

/** Load + refresh the index. Entries are invalidated per file by mtime. */
export function loadIndex({ refresh = true } = {}) {
	let cache = {};
	try { cache = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf8')).entries || {}; } catch { /* cold */ }
	if (!refresh) return Object.values(cache);

	const files = allSessionFiles();
	const next = {};
	let rebuilt = 0;
	for (const file of files) {
		let st;
		try { st = fs.statSync(file); } catch { continue; }
		const prev = cache[file];
		if (prev && prev.mtimeMs === st.mtimeMs) { next[file] = prev; continue; }
		const rec = describeFile(file);
		if (rec) { next[file] = rec; rebuilt++; }
	}
	try {
		fs.writeFileSync(INDEX_PATH, JSON.stringify({ builtAt: new Date().toISOString(), entries: next }));
	} catch { /* index is a cache; failure to persist is not fatal */ }
	return Object.values(next).map(r => ({ ...r, _rebuilt: rebuilt }));
}

/** Rank candidates: exact cwd match, then nearest path prefix, then most recent. */
export function rankCandidates(cands, fromCwd) {
	const cwd = fromCwd || process.cwd();
	const score = (c) => {
		if (!c.cwd) return 0;
		if (c.cwd === cwd) return 1_000_000;
		// Longest shared path prefix, measured in whole segments.
		const a = c.cwd.split('/'), b = cwd.split('/');
		let n = 0;
		while (n < a.length && n < b.length && a[n] === b[n]) n++;
		return n * 1000;
	};
	return [...cands].sort((x, y) => (score(y) - score(x)) || (y.mtimeMs - x.mtimeMs));
}

export class AmbiguousTarget extends Error {
	constructor(target, candidates) {
		super(`'${target}' is ambiguous — ${candidates.length} matches`);
		this.target = target;
		this.candidates = candidates;
	}
}

export class NoMatch extends Error {
	constructor(target) {
		super(`No session matches '${target}'.`);
		this.target = target;
	}
}

/**
 * Resolve a target to a single transcript file.
 * Ambiguity is REJECTED, never auto-picked — same posture as `graveyard peek`.
 */
export function resolve(target, { cwd = process.cwd() } = {}) {
	if (!target) throw new NoMatch('(empty)');
	const t = String(target).trim();

	// --- Tier 1: id / id-prefix. Directory scan only, no file reads. ---
	const files = allSessionFiles();
	const exact = files.filter(f => path.basename(f, '.jsonl') === t);
	if (exact.length === 1) return { file: exact[0], how: 'id' };

	// 2 chars is enough to treat it as an id prefix: listing candidates is far more
	// useful than a bare "not found" when someone types the first few characters.
	const looksLikeId = /^[0-9a-f]{2,}(-[0-9a-f]+)*$/i.test(t);
	if (looksLikeId) {
		const pre = files.filter(f => path.basename(f, '.jsonl').startsWith(t.toLowerCase()));
		if (pre.length === 1) return { file: pre[0], how: 'id-prefix' };
		if (pre.length > 1) {
			throw new AmbiguousTarget(t, rankCandidates(pre.map(describeFile).filter(Boolean), cwd));
		}
	}

	// --- Tier 2: slug / title. Needs the index. ---
	const idx = loadIndex();
	const needle = t.toLowerCase();
	let hits = idx.filter(r => (r.slug || '').toLowerCase() === needle);
	if (!hits.length) hits = idx.filter(r => (r.title || '').toLowerCase() === needle);
	if (!hits.length) {
		hits = idx.filter(r =>
			(r.slug || '').toLowerCase().includes(needle) ||
			(r.title || '').toLowerCase().includes(needle));
	}

	if (!hits.length) throw new NoMatch(t);
	const ranked = rankCandidates(hits, cwd);
	// An exact cwd match is a decisive win; anything else ambiguous gets listed.
	if (ranked.length === 1 || (ranked[0].cwd === cwd && ranked[1].cwd !== cwd)) {
		return { file: ranked[0].file, how: 'name' };
	}
	throw new AmbiguousTarget(t, ranked);
}
