// =============================================================================
// transcript.mjs — the single source of truth for reading Claude Code session
// transcripts (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl).
//
// SOURCE OF TRUTH. Four divergent implementations of this parser existed before
// this file — each stripping noise differently:
//   - plugins/hotline/skills/switchboard/scripts/server.js  (Node, richest)
//   - plugins/hotline/skills/dial/scripts/transcript-extract.sh  (jq)
//   - plugins/session-tools/.../extract_sessions.py  (Python, bulk mining)
//   - ~/.dotfiles/bin/graveyard_lib.php genuineTurns  (PHP, `graveyard peek`)
// This file is the consolidation target. If you change parsing behavior here,
// the vendored copies elsewhere need the same change — see the drift-test task.
//
// Schema notes verified against claude-code 2.1.219 (2026-07):
//   - Filenames ARE the session id, unique across every project dir.
//   - Compaction is `isCompactSummary: true` on a user record. The old
//     `type: "summary"` record NO LONGER EXISTS (zero instances on disk).
//   - Subagent turns are NOT inlined; they live in
//     <project>/<sessionId>/subagents/agent-<id>.jsonl with isSidechain:true
//     and a paired agent-<id>.meta.json.
//   - `thinking` blocks persist with EMPTY text (signature only) — reasoning is
//     unrecoverable, do not plan around it.
//   - Tool output is stored TWICE: the tool_result content block AND a
//     duplicate top-level `.toolUseResult`. Both are dropped here.
//   - ~/.claude/todos/ is empty in 2.1.219; todo state must come from the last
//     TodoWrite tool_use input in the transcript.
// =============================================================================

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export const PROJECTS_ROOT = path.join(os.homedir(), '.claude', 'projects');

// Non-conversational bookkeeping records: no message payload, nothing to show.
export const SKIP_TYPES = new Set([
	'permission-mode', 'mode', 'bridge-session', 'last-prompt',
	'queue-operation', 'custom-title', 'ai-title', 'agent-name',
	'file-history-snapshot', 'file-history-delta', 'attachment',
]);

// Harness-injected blocks. The first five come from switchboard's
// stripSystemNoise; the last two it misses (they appear in any session using a
// slash command or a background task).
const NOISE_PATTERNS = [
	/<system-reminder>[\s\S]*?<\/system-reminder>/g,
	/<command-name>[\s\S]*?<\/command-name>/g,
	/<command-message>[\s\S]*?<\/command-message>/g,
	/<local-command-stdout>[\s\S]*?<\/local-command-stdout>/g,
	/<local-command-caveat>[\s\S]*?<\/local-command-caveat>/g,
	/<task-notification>[\s\S]*?<\/task-notification>/g,
	/<\/?command-args>/g,
];

export function textFromContent(content) {
	if (typeof content === 'string') return content;
	if (!Array.isArray(content)) return '';
	return content
		.filter(b => b && b.type === 'text' && typeof b.text === 'string')
		.map(b => b.text)
		.join('\n');
}

export function stripSystemNoise(text) {
	let out = String(text || '');
	for (const re of NOISE_PATTERNS) out = out.replace(re, '');
	return out.trim();
}

export function toolUseLabel(b) {
	const name = b.name || 'tool';
	const inp = b.input || {};
	let hint = '';
	for (const k of ['command', 'file_path', 'pattern', 'skill', 'description', 'prompt']) {
		if (typeof inp[k] === 'string') { hint = inp[k]; break; }
	}
	hint = String(hint).replace(/\s+/g, ' ').slice(0, 120);
	return hint ? `${name}: ${hint}` : name;
}

export function summarizeToolResult(results) {
	const out = [];
	for (const r of results) {
		let text = typeof r.content === 'string' ? r.content : textFromContent(r.content);
		text = text.replace(/\s+/g, ' ').trim();
		if (text.length > 200) text = text.slice(0, 200) + '…';
		out.push((r.is_error ? '⚠ ' : '') + (text || '(no output)'));
	}
	return out.join('\n');
}

// Synthetic turns that are machinery, not conversation: resume stubs, slash
// command plumbing, and turns whose entire content was harness noise. Modeled
// on graveyard's isSyntheticEntry, which exists for the same reason.
export function isSyntheticEntry(obj, strippedText) {
	if (obj.isMeta) return true;
	if (obj.isVisibleInTranscriptOnly && !obj.isCompactSummary) return true;
	const raw = typeof obj?.message?.content === 'string'
		? obj.message.content
		: textFromContent(obj?.message?.content);
	// A turn that was nothing but a <command-*> / <system-reminder> envelope.
	if (raw && !strippedText) return true;
	if (/^\s*<command-name>/.test(raw)) return true;
	if (/^Caveat: The messages below were generated/.test(raw)) return true;
	return false;
}

/**
 * Parse one JSONL line into a normalized entry, or null to skip.
 * Entries keep tool_use inputs (signals need them); formatters decide what to show.
 */
export function parseLine(line) {
	let obj;
	try { obj = JSON.parse(line); } catch { return null; }
	if (!obj || typeof obj !== 'object') return null;
	if (obj.isSidechain) return null;              // subagent chatter
	if (SKIP_TYPES.has(obj.type)) return null;

	const ts = obj.timestamp || null;

	// Compaction boundary — Claude's own summary of everything before it. High
	// value on catch-up, so it is kept in full.
	if (obj.isCompactSummary === true) {
		const text = typeof obj?.message?.content === 'string'
			? obj.message.content
			: textFromContent(obj?.message?.content);
		return { role: 'system', kind: 'compaction', ts, text: text.trim(), uuid: obj.uuid };
	}

	const msg = obj.message;
	if (!msg) return null;

	if (obj.type === 'user') {
		const content = msg.content;
		if (Array.isArray(content)) {
			const toolResults = content.filter(b => b && b.type === 'tool_result');
			if (toolResults.length && toolResults.length === content.length) {
				// Tool output. Bodies are dropped; only errors survive, truncated.
				const errors = toolResults.filter(r => r.is_error);
				if (!errors.length) return { role: 'tool', kind: 'tool_result', ts, text: '', uuid: obj.uuid };
				return {
					role: 'tool', kind: 'tool_error', ts, uuid: obj.uuid,
					text: summarizeToolResult(errors),
				};
			}
		}
		const text = stripSystemNoise(textFromContent(content));
		if (isSyntheticEntry(obj, text)) return null;
		if (!text) return null;
		return { role: 'user', kind: 'text', ts, text, uuid: obj.uuid };
	}

	if (obj.type === 'assistant') {
		const content = Array.isArray(msg.content) ? msg.content : [];
		const parts = [];
		const toolUses = [];
		for (const b of content) {
			if (!b) continue;
			if (b.type === 'text' && b.text && b.text.trim()) parts.push(b.text);
			if (b.type === 'tool_use') toolUses.push({ id: b.id, name: b.name || 'tool', input: b.input || {}, label: toolUseLabel(b) });
		}
		if (!parts.length && !toolUses.length) return null;
		return {
			role: 'assistant', kind: 'text', ts, uuid: obj.uuid,
			text: stripSystemNoise(parts.join('\n\n')),
			toolUses,
			stopReason: msg.stop_reason || null,
		};
	}

	if (obj.type === 'system') {
		return null; // turn_duration / stop_hook_summary / local_command — no signal
	}

	return null;
}

/** Session identity + liveness. Pulled from the first message-bearing record. */
export function readMeta(filePath, firstObj, lastObj, titles) {
	let st = null;
	try { st = fs.statSync(filePath); } catch { /* ignore */ }
	const mtime = st ? st.mtimeMs : 0;
	const idleMs = Date.now() - mtime;
	return {
		sessionId: firstObj?.sessionId || path.basename(filePath, '.jsonl'),
		cwd: firstObj?.cwd || null,
		gitBranch: lastObj?.gitBranch || firstObj?.gitBranch || null,
		version: firstObj?.version || null,
		slug: lastObj?.slug || firstObj?.slug || null,
		title: titles.custom || titles.ai || null,
		startedAt: firstObj?.timestamp || null,
		lastAt: lastObj?.timestamp || null,
		sizeBytes: st ? st.size : 0,
		mtimeMs: mtime,
		liveness: idleMs < 5 * 60_000 ? 'active' : idleMs < 60 * 60_000 ? 'recent' : 'idle',
		idleMs,
		path: filePath,
	};
}

export function humanIdle(ms) {
	const s = Math.max(0, Math.round(ms / 1000));
	if (s < 90) return `${s}s ago`;
	const m = Math.round(s / 60);
	if (m < 90) return `${m}m ago`;
	const h = Math.round(m / 60);
	if (h < 48) return `${h}h ago`;
	return `${Math.round(h / 24)}d ago`;
}

/**
 * Read + parse a whole transcript. Returns { meta, entries, subagents }.
 * Deliberately a full read: a 5.7 MB file parses in well under the 1s budget,
 * and partial reads would break tail-state detection.
 */
export function parseTranscript(filePath) {
	const raw = fs.readFileSync(filePath, 'utf8');
	const lines = raw.split('\n');
	const entries = [];
	let firstObj = null, lastObj = null;
	const titles = { custom: null, ai: null };

	for (const line of lines) {
		if (!line.trim()) continue;
		// Cheap pre-pass for identity + titles, which live on records parseLine drops.
		if (!firstObj || !titles.custom) {
			try {
				const o = JSON.parse(line);
				if (o && o.sessionId && o.message && !firstObj) firstObj = o;
				if (o && o.sessionId && o.message) lastObj = o;
				if (o && o.type === 'custom-title' && o.title) titles.custom = o.title;
				if (o && o.type === 'ai-title' && o.title) titles.ai = o.title;
				const e = parseLine(line);
				if (e) entries.push(e);
				continue;
			} catch { /* fall through */ }
		}
		try {
			const o = JSON.parse(line);
			if (o && o.sessionId && o.message) lastObj = o;
			if (o && o.type === 'custom-title' && o.title) titles.custom = o.title;
			if (o && o.type === 'ai-title' && o.title) titles.ai = o.title;
		} catch { /* ignore malformed */ }
		const e = parseLine(line);
		if (e) entries.push(e);
	}

	return {
		meta: readMeta(filePath, firstObj, lastObj, titles),
		entries,
		subagents: readSubagents(filePath),
	};
}

/** Subagent dispatches, from the paired meta.json sidecars. Type + description only. */
export function readSubagents(transcriptPath) {
	const dir = path.join(path.dirname(transcriptPath), path.basename(transcriptPath, '.jsonl'), 'subagents');
	let names = [];
	try { names = fs.readdirSync(dir).filter(n => n.endsWith('.meta.json')); } catch { return []; }
	const out = [];
	for (const n of names) {
		try {
			const m = JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8'));
			out.push({ agentType: m.agentType || '?', description: m.description || '', spawnDepth: m.spawnDepth ?? null });
		} catch { /* ignore */ }
	}
	return out;
}

/**
 * Collapse the record stream into conversational turns.
 *
 * Claude Code splits ONE reply across several assistant records: the text in one,
 * each tool_use in its own, with tool_result records interleaved. Rendered raw
 * that is a wall of "(no text — tool calls only)".
 *
 * Merge rule: a tool-only assistant record attaches to the reply above it, but a
 * record that carries its OWN text starts a new turn. Collapsing everything
 * between two user turns instead would fuse twenty distinct replies into one
 * blob and destroy any sense of progression — which matters here, because a
 * slash-command-driven session can legitimately contain a single user turn.
 */
export function mergeConversation(entries) {
	const turns = [];
	for (const e of entries) {
		// A compaction boundary passes through and breaks the merge, which is
		// correct — it is a hard discontinuity in the conversation.
		if (e.kind === 'compaction') { turns.push(e); continue; }
		if (e.role === 'user' && e.kind === 'text') {
			turns.push({ role: 'user', text: e.text, toolUses: [], ts: e.ts });
			continue;
		}
		if (e.role === 'assistant') {
			const last = turns[turns.length - 1];
			const canAttach = last && last.role === 'assistant' && !(e.text && last.text);
			if (canAttach) {
				if (e.text) last.text = last.text ? `${last.text}\n\n${e.text}` : e.text;
				last.toolUses.push(...(e.toolUses || []));
				last.stopReason = e.stopReason;
				last.ts = e.ts;
			} else {
				turns.push({
					role: 'assistant', text: e.text || '',
					toolUses: [...(e.toolUses || [])], ts: e.ts, stopReason: e.stopReason,
				});
			}
		}
		// tool_result / tool_error records deliberately do not break the merge
	}
	return turns;
}

// ---- derived signals --------------------------------------------------------

const BEAD_STOPLIST = new Set([
	'in-progress', 'in_progress', 'dolt-push', 'discovered-from', 'blocked-by',
	'parent-child', 'related-to', 'pull-request', 'up-to-date', 'json', 'no-color',
]);

/** Bead IDs from `bd` invocations only — a loose text regex is too noisy. */
export function extractBeadIds(commands) {
	const ids = new Set();
	const verb = /\bbd\s+(?:dolt\s+\w+|create|update|close|show|dep|defer|supersede|human|ready|list|lint)\b([^\n;|&]*)/g;
	for (const cmd of commands) {
		let m;
		while ((m = verb.exec(cmd)) !== null) {
			const tail = m[1] || '';
			for (const tok of tail.split(/\s+/)) {
				if (!tok || tok.startsWith('-') || tok.includes('/') || tok.includes('=')) continue;
				const clean = tok.replace(/^["']|["',.]$/g, '');
				// Shapes seen in the wild: claude-plugins-kzwk, dotfiles-206, bd-42
				if (/^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$/.test(clean) && !BEAD_STOPLIST.has(clean)) {
					ids.add(clean);
				}
			}
		}
	}
	return [...ids];
}

const EDIT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit', 'MultiEdit']);
const NOTABLE_CMD = /\b(git\s+(commit|push|rebase|merge|revert)|npm\s+(test|run\s+build)|composer\s+test|pytest|phpunit|node\s+--test|make\s+\w+|bd\s+dolt\s+push)\b/;

export function deriveSignals(entries, subagents = []) {
	const files = new Set();
	const commands = [];
	const notable = [];
	const skills = new Set();
	const errors = [];
	let todos = null;
	let compaction = null;
	const toolCounts = new Map();

	for (const e of entries) {
		if (e.kind === 'compaction') { compaction = e; continue; }
		if (e.kind === 'tool_error') { errors.push(e.text); continue; }
		for (const t of e.toolUses || []) {
			toolCounts.set(t.name, (toolCounts.get(t.name) || 0) + 1);
			if (EDIT_TOOLS.has(t.name) && typeof t.input.file_path === 'string') files.add(t.input.file_path);
			if (t.name === 'Bash' && typeof t.input.command === 'string') {
				commands.push(t.input.command);
				if (NOTABLE_CMD.test(t.input.command)) notable.push(t.input.command.replace(/\s+/g, ' ').slice(0, 160));
			}
			if (t.name === 'Skill' && typeof t.input.skill === 'string') skills.add(t.input.skill);
			if (t.name === 'TodoWrite' && Array.isArray(t.input.todos)) todos = t.input.todos;
		}
	}

	return {
		todos,
		compaction,
		files: [...files],
		notableCommands: [...new Set(notable)],
		beadIds: extractBeadIds(commands),
		skills: [...skills],
		errors: errors.slice(-5),
		errorCount: errors.length,
		subagents,
		toolCounts: [...toolCounts.entries()].sort((a, b) => b[1] - a[1]),
		tail: deriveTailState(mergeConversation(entries)),
	};
}

/**
 * Blocked-on-you detection — the highest-value signal on catch-up.
 * A session is "blocked" when the last thing that happened was the agent asking
 * for something: an AskUserQuestion/ExitPlanMode tool_use with no result after
 * it, or a final assistant turn ending in a question.
 */
export function deriveTailState(convo) {
	if (!convo || !convo.length) return { state: 'empty', detail: null };
	const last = convo[convo.length - 1];

	if (last.role === 'assistant') {
		const asks = (last.toolUses || []).filter(t => t.name === 'AskUserQuestion' || t.name === 'ExitPlanMode');
		if (asks.length) {
			return {
				state: 'blocked',
				detail: asks[0].name === 'ExitPlanMode'
					? 'waiting on plan approval'
					: 'waiting on an answer to a direct question',
			};
		}
		const t = (last.text || '').trim();
		if (t.endsWith('?')) {
			return { state: 'blocked', detail: 'last turn ended in a question', question: t.slice(-300) };
		}
		if (last.stopReason === 'tool_use') {
			return { state: 'mid-turn', detail: 'stopped mid tool-use — may have been interrupted' };
		}
		return { state: 'idle-after-agent', detail: 'agent spoke last; nothing explicitly pending' };
	}

	return { state: 'user-spoke-last', detail: 'your message was the last thing in the session — it may never have been answered' };
}
