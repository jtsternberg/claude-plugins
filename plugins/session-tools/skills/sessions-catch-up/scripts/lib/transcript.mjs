// =============================================================================
// transcript.mjs — the single source of truth for reading Claude Code session
// transcripts (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl).
//
// SOURCE OF TRUTH for reading transcripts FOR DISPLAY. One other implementation
// shares that contract and must stay in sync with this file:
//   - plugins/hotline/skills/switchboard/scripts/server.js  (Node)
// tests/parser-drift.test.mjs holds the two together; it caught nothing for months
// because it did not exist, and both of server.js's divergences (two missing noise
// patterns, compaction detected via the dead type:"summary") shipped as a result.
//
// These read transcripts too but are NOT copies of this contract, and were
// measured before being excluded (claude-plugins-207y, -wn09, -ocjd):
//   - hotline/skills/dial/scripts/transcript-extract.sh (jq) — hotline's protocol
//     reader: nonce correlation + STATUS bracketing, none of which lives here. It
//     is deliberately noise-PRESERVING, because stripSystemNoise would delete a
//     harness block an agent legitimately quoted in its answer. Keeping it also
//     keeps hotline installable without session-tools.
//   - sessions-weekly-recap/scripts/extract_sessions.py — now delegates its user
//     messages to export-session.mjs rather than parsing at all.
//   - ~/.dotfiles/src/Graveyard.php genuineTurns (PHP) — different repo; its
//     needles keep <system-reminder> BODIES where this file deletes them, which is
//     load-bearing for graveyard's GATE 2.
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
//     duplicate top-level `.toolUseResult`. The duplicate is always dropped; the
//     content block is dropped for catch-up fidelity and kept (clipped) under
//     `{ archive: true }`, which md/json parse with.
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

export function toolUseLabel(b, max = 120) {
	const name = b.name || 'tool';
	const inp = b.input || {};
	let hint = '';
	for (const k of ['command', 'file_path', 'pattern', 'skill', 'description', 'prompt']) {
		if (typeof inp[k] === 'string') { hint = inp[k]; break; }
	}
	hint = String(hint).replace(/\s+/g, ' ').slice(0, max);
	return hint ? `${name}: ${hint}` : name;
}

// ---- archive fidelity -------------------------------------------------------
// A catch-up card and a permanent archive disagree about what counts as content.
// The card wants human prose and nothing else; the archive has to record what the
// session was ASKED to do and what its tools returned, or it cannot stand in for
// the transcript it replaces. `opts.archive` selects the archive reading.

const ARCHIVE_TOOL_CLIP = 2000;

/** `/foo bar` out of a <command-name>/<command-args> envelope, or null. */
export function parseCommandTurn(raw) {
	const text = String(raw || '');
	const name = text.match(/<command-name>\s*([^<]*?)\s*<\/command-name>/);
	if (!name || !name[1]) return null;
	const args = text.match(/<command-args>([\s\S]*?)<\/command-args>/);
	const cmd = name[1].startsWith('/') ? name[1] : `/${name[1]}`;
	const tail = args ? args[1].replace(/\s+/g, ' ').trim() : '';
	return tail ? `${cmd} ${tail}` : cmd;
}

/** Tool output for an archive: newlines kept, clipped with the elision disclosed. */
export function archiveToolResult(results) {
	const out = [];
	for (const r of results) {
		let text = typeof r.content === 'string' ? r.content : textFromContent(r.content);
		text = text.replace(/[ \t]+$/gm, '').trim();
		if (text.length > ARCHIVE_TOOL_CLIP) {
			const elided = text.length - ARCHIVE_TOOL_CLIP;
			text = text.slice(0, ARCHIVE_TOOL_CLIP) + `\n… _(${elided} chars elided)_`;
		}
		out.push((r.is_error ? '⚠ ' : '') + (text || '(no output)'));
	}
	return out.join('\n');
}

// User-caused events. Harness boilerplate they are not: an interruption is a thing
// the human did, and an archive that drops it misreports the history.
const INTERRUPT_MARKERS = [/^\s*\[Request interrupted by user/, /^\s*\[Request cancelled/];

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
export function isSyntheticEntry(obj, strippedText, opts = {}) {
	if (obj.isMeta) return true;
	if (obj.isVisibleInTranscriptOnly && !obj.isCompactSummary) return true;
	const raw = typeof obj?.message?.content === 'string'
		? obj.message.content
		: textFromContent(obj?.message?.content);
	if (/^Caveat: The messages below were generated/.test(raw)) return true;
	// An archive keeps the command that drove the session and any interruption the
	// user caused; for a catch-up card both are plumbing.
	if (opts.archive) {
		if (parseCommandTurn(raw)) return false;
		if (INTERRUPT_MARKERS.some(re => re.test(strippedText || raw))) return false;
		return raw ? !strippedText : false;
	}
	// A turn that was nothing but a <command-*> / <system-reminder> envelope.
	if (raw && !strippedText) return true;
	if (/^\s*<command-name>/.test(raw)) return true;
	// Harness interrupt markers are not things the user said. Left in, they show up
	// in a catch-up as though they were prompts.
	if (INTERRUPT_MARKERS.some(re => re.test(strippedText || raw))) return true;
	return false;
}

/**
 * Parse one JSONL line into a normalized entry, or null to skip.
 * Entries keep tool_use inputs (signals need them); formatters decide what to show.
 */
export function parseLine(line, opts = {}) {
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

	// A client-side command (/model, /clear) is recorded ONLY as type:"system"
	// subtype:"local_command", with the envelope in a TOP-LEVEL `content` field
	// rather than under `message` — so it must be read before the no-message guard
	// below. Noise on a catch-up card, but it is something the user did, so an
	// archive keeps it. Sweeping 40 real sessions, 2 of the 36 command-bearing ones
	// recorded their command exclusively in this shape.
	if (opts.archive && obj.type === 'system' && obj.subtype === 'local_command') {
		const cmd = parseCommandTurn(obj.content);
		if (cmd) return { role: 'user', kind: 'command', ts, text: cmd, uuid: obj.uuid };
	}

	const msg = obj.message;
	if (!msg) return null;

	if (obj.type === 'user') {
		const content = msg.content;
		if (Array.isArray(content)) {
			const toolResults = content.filter(b => b && b.type === 'tool_result');
			if (toolResults.length && toolResults.length === content.length) {
				// An archive keeps the output (clipped) keyed to the call that made it;
				// a catch-up card drops bodies and surfaces only errors.
				if (opts.archive) {
					return {
						role: 'tool', kind: toolResults.some(r => r.is_error) ? 'tool_error' : 'tool_result',
						ts, uuid: obj.uuid, toolUseId: toolResults[0].tool_use_id || null,
						text: archiveToolResult(toolResults),
					};
				}
				const errors = toolResults.filter(r => r.is_error);
				if (!errors.length) return { role: 'tool', kind: 'tool_result', ts, text: '', uuid: obj.uuid };
				return {
					role: 'tool', kind: 'tool_error', ts, uuid: obj.uuid,
					text: summarizeToolResult(errors),
				};
			}
		}
		const text = stripSystemNoise(textFromContent(content));
		// Checked before the prose path: stripping removes the <command-args> TAGS but
		// keeps their body, so a command turn otherwise survives as its bare arguments
		// ("#2407") with the command that gives them meaning thrown away.
		if (opts.archive) {
			const raw = typeof content === 'string' ? content : textFromContent(content);
			const cmd = parseCommandTurn(raw);
			if (cmd) return { role: 'user', kind: 'command', ts, text: cmd, uuid: obj.uuid };
		}
		if (isSyntheticEntry(obj, text, opts)) return null;
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
			if (b.type === 'tool_use') toolUses.push({ id: b.id, name: b.name || 'tool', input: b.input || {}, label: toolUseLabel(b, opts.archive ? 400 : 120) });
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
		return null; // turn_duration / stop_hook_summary — no signal
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
export function parseTranscript(filePath, opts = {}) {
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
				const e = parseLine(line, opts);
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
		const e = parseLine(line, opts);
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
const norm = (s) => String(s || '').replace(/\s+/g, ' ').trim();

/**
 * Comparison key for detecting a replayed prompt.
 *
 * Switching modes re-submits the pending prompt with the slash command appended, so
 * the two records are not byte-identical: the replay is `<original>\n/plan`. Strip
 * trailing bare slash-command lines before comparing.
 */
export function promptKey(text) {
	let t = String(text || '').replace(/\n\s*\/[a-z0-9][\w:-]*\s*$/gi, '');
	return norm(t).toLowerCase();
}

/** True when two prompts are the same ask — equal keys, or one a prefix of the other. */
export function samePrompt(a, b) {
	const ka = promptKey(a), kb = promptKey(b);
	if (!ka || !kb) return false;
	if (ka === kb) return true;
	// A replay can also gain/lose a trailing fragment; only trust prefix-containment
	// on prompts long enough that the coincidence is implausible.
	const [short, long] = ka.length <= kb.length ? [ka, kb] : [kb, ka];
	return short.length >= 60 && long.startsWith(short);
}

export function mergeConversation(entries, opts = {}) {
	const turns = [];
	for (const e of entries) {
		// Archive rendering pins each tool's output to the call that produced it, by
		// tool_use_id — the pairing the raw record stream only implies by adjacency.
		if (opts.attachToolResults && e.role === 'tool' && e.toolUseId && e.text) {
			for (let i = turns.length - 1; i >= 0; i--) {
				const hit = (turns[i].toolUses || []).find(t => t.id === e.toolUseId);
				if (hit) { hit.output = e.text; break; }
			}
			continue;
		}
		// A compaction boundary passes through and breaks the merge, which is
		// correct — it is a hard discontinuity in the conversation.
		if (e.kind === 'compaction') { turns.push(e); continue; }
		if (e.role === 'user' && (e.kind === 'text' || e.kind === 'command')) {
			const prev = turns[turns.length - 1];
			// Replay dedupe: switching modes (e.g. /plan) re-submits the pending prompt,
			// so the transcript holds two user records with identical text and different
			// promptIds. Only collapse CONSECUTIVE identical prompts — with an assistant
			// turn between them it is a real re-ask and should be kept.
			if (prev && prev.role === 'user' && samePrompt(prev.text, e.text)) continue;
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

/**
 * Bead IDs from `bd` invocations only.
 *
 * Deliberately narrow: only verbs that TAKE an id, and only the first one or two
 * positional tokens after the verb. `bd create` is skipped entirely — it has no id
 * argument (the id is generated), and its title/description text is full of
 * hyphenated words that look exactly like ids. Scanning whole command tails
 * produced false positives like `post-compact`, `co-worker`, and `opt-in`.
 */
export function extractBeadIds(commands) {
	const ids = new Set();
	const verb = /\bbd\s+(update|close|show|dep|defer|supersede|human|reopen|comment)\s+([^\n;|&]*)/g;
	for (const cmd of commands) {
		let m;
		while ((m = verb.exec(cmd)) !== null) {
			const isDep = m[1] === 'dep';
			let taken = 0;
			for (const tok of (m[2] || '').split(/\s+/)) {
				if (!tok) continue;
				if (tok.startsWith('-')) break;          // flags end the positional run
				if (isDep && /^(add|remove|list)$/.test(tok)) continue;  // `bd dep add A B`
				const clean = tok.replace(/^["']|["',.]$/g, '');
				// Shapes seen in the wild: claude-plugins-kzwk, dotfiles-206, bd-42
				if (/^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$/.test(clean) && !BEAD_STOPLIST.has(clean)) {
					ids.add(clean);
				}
				if (++taken >= (isDep ? 2 : 1)) break;   // only the id argument(s)
			}
		}
	}
	return [...ids];
}

/**
 * The interesting LINE of a multi-line command, not the whole blob.
 * Flattening whitespace turned `git commit -F - <<'MSG' … MSG` into 160 chars of
 * commit-message body, which is noise: the point is that a commit happened.
 */
export function notableLine(command) {
	const lines = String(command).split('\n').map(l => l.trim()).filter(Boolean);
	const hit = lines.find(l => NOTABLE_CMD.test(l)) || lines[0] || '';
	const flat = hit.replace(/\s+/g, ' ');
	return flat.length > 140 ? flat.slice(0, 140) + '…' : flat;
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
				if (NOTABLE_CMD.test(t.input.command)) notable.push(notableLine(t.input.command));
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
