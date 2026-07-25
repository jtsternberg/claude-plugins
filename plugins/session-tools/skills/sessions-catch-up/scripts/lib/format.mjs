// =============================================================================
// format.mjs — render parsed transcript data. Pure: no I/O, no child processes.
//
// The digest format is deliberately ASYMMETRIC, which is the whole reason not to
// just use /export: tool-result bodies are gone, tool calls collapse to one-line
// labels, old turns compress to a timeline, recent turns stay near-verbatim, and
// derived signals (tail state, todos, beads, files) get top billing.
// =============================================================================

import { humanIdle, mergeConversation } from './transcript.mjs';

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

function renderTurn(e, truncAt) {
	const who = e.role === 'user' ? '**You:**' : '**Claude:**';
	const lines = [];
	const text = trunc(e.text, truncAt);
	if (text) lines.push(`${who} ${text}`);
	else lines.push(`${who} _(no text — tool calls only)_`);
	const tools = (e.toolUses || []).map(t => t.label);
	if (tools.length) {
		lines.push(`  ↳ ${tools.slice(0, 8).map(t => `\`${oneLine(t, 100)}\``).join(', ')}${tools.length > 8 ? ` +${tools.length - 8} more` : ''}`);
	}
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
	for (const e of older) {
		for (const t of e.toolUses || []) toolTally.set(t.name, (toolTally.get(t.name) || 0) + 1);
		if (e.role === 'user') out.push(`- ${oneLine(e.text, 200)}`);
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

export function formatDigest(data, opts = {}) {
	const { meta, entries, signals } = data;
	const window = opts.window ?? 12;
	const maxChars = opts.maxChars ?? 40000;
	const resolvedBeads = opts.resolvedBeads || {};

	const convo = conversational(entries);

	const build = (win, truncAt, timelinePrompts) => {
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
			// KB. Capped so it cannot eat the whole budget on the fast path.
			const cap = opts.compactionCap ?? 8000;
			L.push(trunc(signals.compaction.text, cap));
			if (signals.compaction.text.length > cap) {
				L.push('');
				L.push(`_(compaction summary truncated at ${cap} chars — re-run with \`--compaction-full\` for all ${signals.compaction.text.length}.)_`);
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
	// (per-turn detail, then the least-valuable section, then the window) and a final
	// clamp guarantees the contract even at absurdly small budgets.
	let win = window;
	let truncAt = opts.truncAt ?? TURN_TRUNC_DEFAULT;
	let prompts = 25;
	let out = build(win, truncAt, prompts);
	while (out.length > maxChars && truncAt > 400) { truncAt = Math.floor(truncAt / 2); out = build(win, truncAt, prompts); }
	while (out.length > maxChars && prompts > 3) { prompts = Math.max(3, Math.floor(prompts / 2)); out = build(win, truncAt, prompts); }
	while (out.length > maxChars && win > 4) { win = Math.max(4, win - 3); out = build(win, truncAt, prompts); }

	// Reserve room for the header, which is prepended below — the ceiling covers the
	// whole returned string, not just the body.
	const HEADER_RESERVE = 220;
	let clamped = false;
	if (out.length > maxChars - HEADER_RESERVE) {
		out = out.slice(0, Math.max(0, maxChars - HEADER_RESERVE)).replace(/\n[^\n]*$/, '')
			+ '\n\n_…digest clamped to the --max-chars budget._\n';
		clamped = true;
	}

	const ratio = meta.sizeBytes ? (meta.sizeBytes / Math.max(1, out.length)) : 0;
	const header = `<!-- digest ${fmtBytes(out.length)} from ${fmtBytes(meta.sizeBytes)} — ${ratio.toFixed(0)}x reduction · window=${win} trunc=${truncAt}${clamped ? ' CLAMPED' : ''} -->\n`;
	return header + out;
}

/** Full readable transcript — the `/export` replacement shape. */
export function formatMd(data) {
	const { meta, entries } = data;
	const L = [`# ${meta.title || meta.slug || meta.sessionId}`, ''];
	L.push(`- session \`${meta.sessionId}\``);
	L.push(`- cwd \`${meta.cwd || '(unknown)'}\`${meta.gitBranch ? ` · branch \`${meta.gitBranch}\`` : ''}`);
	L.push(`- ${meta.startedAt || '?'} → ${meta.lastAt || '?'}`);
	L.push('');
	for (const e of mergeConversation(entries)) {
		if (e.kind === 'compaction') { L.push('---', '', '### ⟲ Context compacted', '', e.text, ''); continue; }
		L.push(renderTurn(e, 1e9), '');
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
