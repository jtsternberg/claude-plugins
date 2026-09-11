// =============================================================================
// format.mjs — render parsed transcript data. Pure: no I/O, no child processes.
//
// The digest format is deliberately ASYMMETRIC, which is the whole reason not to
// just use /export: tool-result bodies are gone, tool calls collapse to one-line
// labels, old turns compress to a timeline, recent turns stay near-verbatim, and
// derived signals (tail state, todos, beads, files) get top billing.
// =============================================================================

import { humanIdle, mergeConversation, promptKey, samePrompt } from './transcript.mjs';

const TURN_TRUNC_DEFAULT = 2000;

function fmtBytes(n) {
	if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
	if (n >= 1024) return `${Math.round(n / 1024)} KB`;
	return `${n} B`;
}

function trunc(s, n) {
	const t = String(s || '').trim();
	return t.length > n ? t.slice(0, n) + '…' : t;
}

function oneLine(s, n) {
	return trunc(String(s || '').replace(/\s+/g, ' '), n);
}

/** Merged turns, minus compaction markers (the digest renders those separately). */
function conversational(entries) {
	return mergeConversation(entries).filter(e => e.kind !== 'compaction');
}

function renderTurn(e, truncAt, opts = {}) {
	const who = e.role === 'user' ? '**You:**' : '**Claude:**';
	const lines = [];
	const text = trunc(e.text, truncAt);
	if (text) lines.push(`${who} ${text}`);
	else lines.push(`${who} _(no text — tool calls only)_`);
	const tools = e.toolUses || [];
	if (!tools.length) return lines.join('\n');

	// An archive lists every call and what it returned; the digest collapses the lot
	// to one line of labels, because there the point is only that work happened.
	if (opts.archive) {
		for (const t of tools) {
			lines.push(`  ↳ \`${oneLine(t.label, 400)}\``);
			if (t.output) lines.push(t.output.split('\n').map(l => `      ${l}`).join('\n'));
		}
		return lines.join('\n');
	}
	const labels = tools.map(t => t.label);
	lines.push(`  ↳ ${labels.slice(0, 8).map(t => `\`${oneLine(t, 100)}\``).join(', ')}${labels.length > 8 ? ` +${labels.length - 8} more` : ''}`);
	return lines.join('\n');
}

function renderTodos(todos) {
	if (!todos || !todos.length) return null;
	const mark = (s) => s === 'completed' ? 'x' : s === 'in_progress' ? '~' : ' ';
	return todos.map(t => `- [${mark(t.status)}] ${oneLine(t.content || t.activeForm || '', 140)}${t.status === 'in_progress' ? '  ← in progress' : ''}`).join('\n');
}

function renderBeads(beadIds, resolved) {
	if (!beadIds || !beadIds.length) return null;
	return beadIds.map(id => {
		const r = resolved && resolved[id];
		if (!r) return `- \`${id}\` _(not resolvable locally)_`;
		const open = r.status && r.status !== 'closed';
		return `- \`${id}\` — ${oneLine(r.title, 110)} · **${r.status}**${open ? ' ⟵ still open' : ''}`;
	}).join('\n');
}

/** Compressed pre-window timeline: one line per user turn + a tool histogram. */
function renderTimeline(older, maxPrompts = 25) {
	if (!older.length) return null;
	let out = [];
	const toolTally = new Map();
	// Dedupe identical prompts regardless of position. A mode switch (/plan) replays
	// the pending prompt, and by then assistant turns sit between the two copies, so
	// adjacency-based dedupe misses it. This is a compressed overview — a repeated
	// prompt adds nothing here even when the repeat was genuine.
	const seenPrompts = [];
	for (const e of older) {
		for (const t of e.toolUses || []) toolTally.set(t.name, (toolTally.get(t.name) || 0) + 1);
		if (e.role !== 'user') continue;
		if (!promptKey(e.text)) continue;
		if (seenPrompts.some(p => samePrompt(p, e.text))) continue;
		seenPrompts.push(e.text);
		out.push(`- ${oneLine(e.text, 200)}`);
	}
	// A long session can have hundreds of earlier prompts; the most recent ones
	// are the ones that explain where it ended up.
	const dropped = Math.max(0, out.length - maxPrompts);
	if (dropped) out = [`- _…${dropped} earlier prompts omitted…_`, ...out.slice(-maxPrompts)];
	const tools = [...toolTally.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)
		.map(([n, c]) => `${n}×${c}`).join(' · ');
	const span = [older[0]?.ts, older[older.length - 1]?.ts]
		.filter(Boolean).map(t => t.slice(0, 16).replace('T', ' '));
	const parts = [];
	parts.push(`_${older.length} earlier turns${span.length === 2 ? `, ${span[0]} → ${span[1]}` : ''}._`);
	if (out.length) parts.push(`Your prompts in that stretch:\n${out.join('\n')}`);
	if (tools) parts.push(`Tool activity: ${tools}`);
	return parts.join('\n\n');
}

const RECENT_HEADING = '\n## Recent turns';
const CLAMP_MARK = '\n\n_…digest clamped to the --max-chars budget._\n';
const COMPACTION_CAP_FLOOR = 800;

/**
 * Cut `s` to `n` chars on a line boundary — but only when the partial line being
 * dropped is small. A one-line compaction summary is a single 8000-char "line", so
 * an unconditional walk-back to the previous newline threw away the whole budget
 * (an 8000-char budget once returned 493 chars).
 */
function cutLines(s, n) {
	if (s.length <= Math.max(0, n)) return s;
	const cut = s.slice(0, Math.max(0, n));
	const nl = cut.lastIndexOf('\n');
	return nl >= 0 && cut.length - nl <= 200 ? cut.slice(0, nl) : cut;
}

/**
 * Keep the heading plus as many of the NEWEST turns as `budget` allows. Reached only
 * when the whole Recent-turns section overruns the budget on its own; shedding from
 * the front is what keeps the last turn — the point of the section — present.
 */
function keepNewestTurns(tail, budget) {
	const nl = tail.indexOf('\n', 1);
	const heading = nl < 0 ? tail : tail.slice(0, nl);
	const turns = (nl < 0 ? '' : tail.slice(nl + 1)).trim().split(/\n{2,}(?=\*\*(?:You|Claude):\*\*)/);
	const room = Math.max(0, budget - heading.length - 2);
	const kept = [];
	let used = 0;
	for (let i = turns.length - 1; i >= 0; i--) {
		const t = turns[i].trim();
		const cost = t.length + (kept.length ? 2 : 0);
		if (kept.length && used + cost > room) break;
		used += cost;
		kept.unshift(t);
	}
	// Truncating the newest turn is the last resort: a cut-off turn beats no turn.
	if (used > room) kept[0] = cutLines(kept[0], room);
	return `${heading.replace(/\(last \d+\)/, `(last ${kept.length})`)}\n\n${kept.join('\n\n')}`;
}

/**
 * Final guarantee that the whole string fits. Cuts from the sections ABOVE
 * `## Recent turns`, never from the tail: the newest turns are the one thing a
 * catch-up digest cannot be useful without, and they render last.
 */
function clampDigest(out, limit) {
	const budget = Math.max(0, limit - CLAMP_MARK.length);
	const idx = out.lastIndexOf(RECENT_HEADING);
	if (idx < 0) return cutLines(out, budget) + CLAMP_MARK;
	const head = out.slice(0, idx);
	const tail = out.slice(idx);
	const keptTail = tail.length <= budget ? tail : keepNewestTurns(tail, budget);
	return cutLines(head, budget - keptTail.length) + CLAMP_MARK + keptTail;
}

export function formatDigest(data, opts = {}) {
	const { meta, entries, signals } = data;
	const window = opts.window ?? 12;
	const maxChars = opts.maxChars ?? 40000;
	const resolvedBeads = opts.resolvedBeads || {};

	const convo = conversational(entries);

	const build = (win, truncAt, timelinePrompts, compactionCap) => {
		const recent = convo.slice(-win);
		const older = convo.slice(0, Math.max(0, convo.length - win));
		const L = [];

		const id8 = (meta.sessionId || '').slice(0, 8);
		L.push(`# ${meta.title || meta.slug || id8} — catch-up digest`);
		L.push('');
		L.push(`- **session** \`${meta.sessionId}\``);
		L.push(`- **cwd** \`${meta.cwd || '(unknown)'}\`${meta.gitBranch ? ` · branch \`${meta.gitBranch}\`` : ''}`);
		L.push(`- **last activity** ${humanIdle(meta.idleMs)} (${meta.liveness})${meta.startedAt ? ` · started ${meta.startedAt.slice(0, 16).replace('T', ' ')}` : ''}`);
		const yours = convo.filter(e => e.role === 'user').length;
		L.push(`- **size** ${convo.length} turns (${yours} from you) · transcript ${fmtBytes(meta.sizeBytes)}`);
		if (meta.version) L.push(`- **claude-code** ${meta.version}`);
		L.push('');

		// Tail state first — it is the answer to "what's waiting on me".
		const tail = signals.tail;
		L.push('## ⏳ Tail state');
		const flag = tail.state === 'blocked' ? '**BLOCKED ON YOU**'
			: tail.state === 'user-spoke-last' ? '**YOUR MESSAGE MAY BE UNANSWERED**'
			: tail.state === 'mid-turn' ? '**INTERRUPTED MID-TURN**'
			: 'Not blocked';
		L.push(`${flag} — ${tail.detail || ''}`);
		if (tail.question) { L.push(''); L.push('> ' + oneLine(tail.question, 300)); }
		L.push('');

		const todos = renderTodos(signals.todos);
		if (todos) { L.push('## Todo state (last TodoWrite)'); L.push(todos); L.push(''); }

		const beads = renderBeads(signals.beadIds, resolvedBeads);
		if (beads) { L.push('## Beads referenced'); L.push(beads); L.push(''); }

		if (signals.files.length) {
			L.push(`## Files touched (${signals.files.length})`);
			L.push(signals.files.slice(0, 30).map(f => `- \`${f}\``).join('\n'));
			if (signals.files.length > 30) L.push(`- _…and ${signals.files.length - 30} more_`);
			L.push('');
		}

		if (signals.notableCommands.length) {
			L.push('## Notable commands');
			L.push(signals.notableCommands.slice(0, 15).map(c => `- \`${c}\``).join('\n'));
			L.push('');
		}

		if (signals.skills.length) { L.push(`## Skills invoked`); L.push(signals.skills.map(s => `- \`${s}\``).join('\n')); L.push(''); }

		if (signals.subagents.length) {
			L.push(`## Subagents dispatched (${signals.subagents.length})`);
			L.push(signals.subagents.slice(0, 15).map(s => `- **${s.agentType}** — ${oneLine(s.description, 120)}`).join('\n'));
			L.push('');
		}

		if (signals.errorCount) {
			L.push(`## Errors (${signals.errorCount} total, last ${signals.errors.length})`);
			L.push(signals.errors.map(e => `- ${oneLine(e, 200)}`).join('\n'));
			L.push('');
		}

		if (signals.compaction) {
			L.push('## Compaction summary');
			L.push('_This session was compacted. Everything before this point exists only as this summary._');
			L.push('');
			// High-value (it is Claude's own structured summary) but can run to tens of
			// KB. Capped so it cannot eat the whole budget on the fast path, and the cap
			// shrinks further as a budget rung below.
			L.push(trunc(signals.compaction.text, compactionCap));
			if (signals.compaction.text.length > compactionCap) {
				L.push('');
				L.push(`_(compaction summary truncated at ${compactionCap} chars — re-run with \`--compaction-full\` for all ${signals.compaction.text.length}.)_`);
			}
			L.push('');
		}

		const timeline = renderTimeline(older, timelinePrompts);
		if (timeline) { L.push(`## Earlier (compressed)`); L.push(timeline); L.push(''); }

		L.push(`## Recent turns (last ${recent.length})`);
		L.push('');
		for (const e of recent) { L.push(renderTurn(e, truncAt)); L.push(''); }

		return L.join('\n');
	};

	// Budget guard. `maxChars` is a hard ceiling, so the ladder runs cheapest-first
	// (per-turn detail, the compressed timeline, the compaction summary, then the
	// window) and a final clamp guarantees the contract even at absurdly small budgets.
	let win = window;
	let truncAt = opts.truncAt ?? TURN_TRUNC_DEFAULT;
	let prompts = 25;
	let cap = opts.compactionCap ?? 8000;
	let out = build(win, truncAt, prompts, cap);
	while (out.length > maxChars && truncAt > 400) { truncAt = Math.floor(truncAt / 2); out = build(win, truncAt, prompts, cap); }
	while (out.length > maxChars && prompts > 3) { prompts = Math.max(3, Math.floor(prompts / 2)); out = build(win, truncAt, prompts, cap); }
	// The compaction summary sheds before the window does: on a compacted session its
	// cap alone can exceed the budget, and shrinking the window instead used to leave
	// the summary intact and the newest turns gone. `--compaction-full` passes Infinity,
	// so the first step down has to come off the real text length.
	while (out.length > maxChars && cap > COMPACTION_CAP_FLOOR) {
		const finite = Number.isFinite(cap) ? cap : (signals.compaction?.text.length ?? COMPACTION_CAP_FLOOR);
		cap = Math.max(COMPACTION_CAP_FLOOR, Math.floor(finite / 2));
		out = build(win, truncAt, prompts, cap);
	}
	while (out.length > maxChars && win > 4) { win = Math.max(4, win - 3); out = build(win, truncAt, prompts, cap); }

	// Reserve room for the header, which is prepended below — the ceiling covers the
	// whole returned string, not just the body.
	const HEADER_RESERVE = 220;
	let clamped = false;
	if (out.length > maxChars - HEADER_RESERVE) {
		out = clampDigest(out, maxChars - HEADER_RESERVE);
		clamped = true;
	}

	const ratio = meta.sizeBytes ? (meta.sizeBytes / Math.max(1, out.length)) : 0;
	const header = `<!-- digest ${fmtBytes(out.length)} from ${fmtBytes(meta.sizeBytes)} — ${ratio.toFixed(0)}x reduction · window=${win} trunc=${truncAt}${clamped ? ' CLAMPED' : ''} -->\n`;
	return header + out;
}

/**
 * Full readable transcript — the `/export` replacement shape, and the format
 * graveyard archives with. Full fidelity is the contract here, not a nicety: an
 * archive that drops the slash command a session opened with no longer records
 * what that session was asked to do, and one that drops tool output no longer
 * shows what its work actually returned. Feed it entries parsed with
 * `{ archive: true }` — without that the parse layer has already discarded both.
 */
export function formatMd(data) {
	const { meta, entries } = data;
	const L = [`# ${meta.title || meta.slug || meta.sessionId}`, ''];
	L.push(`- session \`${meta.sessionId}\``);
	L.push(`- cwd \`${meta.cwd || '(unknown)'}\`${meta.gitBranch ? ` · branch \`${meta.gitBranch}\`` : ''}`);
	L.push(`- ${meta.startedAt || '?'} → ${meta.lastAt || '?'}`);
	L.push('');
	for (const e of mergeConversation(entries, { attachToolResults: true })) {
		if (e.kind === 'compaction') { L.push('---', '', '### ⟲ Context compacted', '', e.text, ''); continue; }
		L.push(renderTurn(e, 1e9, { archive: true }), '');
	}
	return L.join('\n');
}

export function formatText(data) {
	return conversational(data.entries)
		.map(e => `${e.role === 'user' ? '❯' : '⏺'} ${oneLine(e.text, 100000)}`)
		.join('\n\n');
}

export function formatJson(data) {
	return JSON.stringify(data, null, 2);
}
