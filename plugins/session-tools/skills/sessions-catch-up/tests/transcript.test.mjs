// Run: node --test plugins/session-tools/skills/sessions-catch-up/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
	parseLine, mergeConversation, deriveSignals, deriveTailState,
	stripSystemNoise, extractBeadIds, textFromContent, toolUseLabel, notableLine,
	promptKey, samePrompt,
} from '../scripts/lib/transcript.mjs';
import { describeFile, rankCandidates } from '../scripts/lib/session-index.mjs';
import { formatDigest } from '../scripts/lib/format.mjs';
import { decide } from '../scripts/nudge.mjs';

const J = (o) => JSON.stringify(o);
const base = { sessionId: 's1', cwd: '/tmp/proj', gitBranch: 'main', timestamp: '2026-07-25T10:00:00.000Z', version: '2.1.219' };

const userText = (text, extra = {}) => J({ ...base, type: 'user', uuid: 'u1', message: { role: 'user', content: text }, ...extra });
const userBlocks = (text) => J({ ...base, type: 'user', uuid: 'u2', message: { role: 'user', content: [{ type: 'text', text }] } });
const asst = (text, toolUses = [], extra = {}) => J({
	...base, type: 'assistant', uuid: 'a' + Math.random(), isSidechain: false,
	message: { role: 'assistant', stop_reason: extra.stop_reason || 'end_turn', content: [
		...(text ? [{ type: 'text', text }] : []),
		...toolUses.map((t, i) => ({ type: 'tool_use', id: 't' + i, name: t.name, input: t.input || {} })),
	] },
});
const toolResult = (content, is_error = false) => J({
	...base, type: 'user', uuid: 'tr' + Math.random(), toolUseResult: { big: 'x'.repeat(500) },
	message: { role: 'user', content: [{ type: 'tool_result', content, is_error }] },
});

test('drops subagent (isSidechain) records', () => {
	assert.equal(parseLine(J({ ...base, type: 'assistant', isSidechain: true, message: { role: 'assistant', content: [{ type: 'text', text: 'hi' }] } })), null);
});

test('drops isMeta records and bookkeeping types', () => {
	assert.equal(parseLine(userText('injected context', { isMeta: true })), null);
	for (const type of ['permission-mode', 'mode', 'bridge-session', 'last-prompt', 'attachment', 'queue-operation', 'file-history-snapshot']) {
		assert.equal(parseLine(J({ ...base, type })), null, type);
	}
});

test('handles user content as bare string AND as block array', () => {
	assert.equal(parseLine(userText('plain string')).text, 'plain string');
	assert.equal(parseLine(userBlocks('from blocks')).text, 'from blocks');
});

test('strips harness noise, including the two switchboard misses', () => {
	const t = stripSystemNoise('keep <system-reminder>drop</system-reminder> <local-command-caveat>drop</local-command-caveat> <task-notification>drop</task-notification> this');
	assert.match(t, /^keep/);
	assert.match(t, /this$/);
	for (const bad of ['system-reminder', 'local-command-caveat', 'task-notification']) assert.ok(!t.includes(bad), bad);
});

test('a turn that was nothing but a command envelope is dropped as synthetic', () => {
	assert.equal(parseLine(userText('<command-name>/aiqrank</command-name>')), null);
});

test('detects compaction via isCompactSummary, not type:"summary"', () => {
	const e = parseLine(J({ ...base, type: 'user', isCompactSummary: true, message: { role: 'user', content: 'Summary:\n1. Intent' } }));
	assert.equal(e.kind, 'compaction');
	assert.match(e.text, /Summary/);
	// The legacy record type no longer exists and must not be relied on.
	assert.equal(parseLine(J({ ...base, type: 'summary', summary: 'old' })), null);
});

test('suppresses tool_result bodies but keeps errors truncated', () => {
	const ok = parseLine(toolResult('x'.repeat(5000)));
	assert.equal(ok.kind, 'tool_result');
	assert.equal(ok.text, '', 'successful tool output must not leak');

	const bad = parseLine(toolResult('boom: permission denied', true));
	assert.equal(bad.kind, 'tool_error');
	assert.match(bad.text, /boom/);
	assert.ok(bad.text.length < 260, 'errors are truncated');
});

test('merge: tool-only records attach, text-bearing records start a new turn', () => {
	const entries = [
		parseLine(userText('do the thing')),
		parseLine(asst('first reply', [{ name: 'Read', input: { file_path: '/a' } }])),
		parseLine(asst('', [{ name: 'Bash', input: { command: 'ls' } }])),   // attaches
		parseLine(toolResult('output')),
		parseLine(asst('second reply')),                                      // new turn
	].filter(Boolean);

	const turns = mergeConversation(entries);
	assert.deepEqual(turns.map(t => t.role), ['user', 'assistant', 'assistant']);
	assert.equal(turns[1].text, 'first reply');
	assert.equal(turns[1].toolUses.length, 2, 'tool-only record folded in');
	assert.equal(turns[2].text, 'second reply');
});

test('compaction breaks the merge', () => {
	const entries = [
		parseLine(asst('before')),
		parseLine(J({ ...base, type: 'user', isCompactSummary: true, message: { role: 'user', content: 'SUMMARY' } })),
		parseLine(asst('after')),
	].filter(Boolean);
	assert.deepEqual(mergeConversation(entries).map(t => t.kind || t.role), ['assistant', 'compaction', 'assistant']);
});

test('tail state: AskUserQuestion and ExitPlanMode both read as blocked', () => {
	for (const name of ['AskUserQuestion', 'ExitPlanMode']) {
		const turns = mergeConversation([parseLine(userText('go')), parseLine(asst('', [{ name }]))].filter(Boolean));
		assert.equal(deriveTailState(turns).state, 'blocked', name);
	}
});

test('tail state: trailing question, user-spoke-last, and not-blocked', () => {
	const q = mergeConversation([parseLine(asst('Which one do you want?'))].filter(Boolean));
	assert.equal(deriveTailState(q).state, 'blocked');

	const u = mergeConversation([parseLine(asst('done')), parseLine(userText('thanks'))].filter(Boolean));
	assert.equal(deriveTailState(u).state, 'user-spoke-last');

	const done = mergeConversation([parseLine(userText('go')), parseLine(asst('All finished.'))].filter(Boolean));
	assert.equal(deriveTailState(done).state, 'idle-after-agent');

	assert.equal(deriveTailState([]).state, 'empty');
});

test('extracts the last TodoWrite state', () => {
	const entries = [
		parseLine(asst('', [{ name: 'TodoWrite', input: { todos: [{ content: 'old', status: 'pending' }] } }])),
		parseLine(asst('', [{ name: 'TodoWrite', input: { todos: [{ content: 'new', status: 'in_progress' }] } }])),
	].filter(Boolean);
	const s = deriveSignals(entries);
	assert.equal(s.todos.length, 1);
	assert.equal(s.todos[0].content, 'new', 'last TodoWrite wins');
});

test('bead ids come from bd invocations, not loose text', () => {
	const ids = extractBeadIds([
		'bd update claude-plugins-kzwk --status in_progress',
		'bd close dotfiles-206 --reason done',
		'bd show bd-42 --json',
		'echo some-random-hyphenated-thing',      // not a bd command → ignored
		'bd ready --json',
	]);
	assert.ok(ids.includes('claude-plugins-kzwk'));
	assert.ok(ids.includes('dotfiles-206'));
	assert.ok(ids.includes('bd-42'));
	assert.ok(!ids.includes('some-random-hyphenated-thing'));
	assert.ok(!ids.includes('in_progress'), 'stoplist filters status words');
});

// Regression: found by running the digest against a real session. `bd create` has
// no id argument, and scanning its title/description produced ids out of ordinary
// hyphenated words.
test('bd create text does not yield phantom bead ids', () => {
	const ids = extractBeadIds([
		'bd create "handoff: portable/durable handoff flag (cross-machine, co-worker)" --description="post-compact nudge, git-exclude litter fix, read-once pickup, opt-in flag"',
		'bd close claude-plugins-jew0 --reason "shipped"',
	]);
	assert.deepEqual(ids, ['claude-plugins-jew0']);
	for (const phantom of ['post-compact', 'co-worker', 'opt-in', 'git-exclude', 'read-once', 'cross-machine']) {
		assert.ok(!ids.includes(phantom), `phantom id leaked: ${phantom}`);
	}
});

test('bead ids stop at flags and handle `bd dep add A B`', () => {
	assert.deepEqual(extractBeadIds(['bd show my-bead-1 --json']), ['my-bead-1']);
	assert.deepEqual(extractBeadIds(['bd dep add left-1 right-2']).sort(), ['left-1', 'right-2']);
	assert.deepEqual(extractBeadIds(['bd ready --json']), [], 'ready takes no id');
});

test('signals collect files, notable commands, skills, errors, tool counts', () => {
	const entries = [
		parseLine(asst('', [{ name: 'Edit', input: { file_path: '/a.js' } }, { name: 'Write', input: { file_path: '/b.js' } }])),
		parseLine(asst('', [{ name: 'Bash', input: { command: 'git commit -m wip' } }])),
		parseLine(asst('', [{ name: 'Skill', input: { skill: 'superpowers:brainstorming' } }])),
		parseLine(toolResult('nope', true)),
	].filter(Boolean);
	const s = deriveSignals(entries, [{ agentType: 'Explore', description: 'look around' }]);
	assert.deepEqual(s.files.sort(), ['/a.js', '/b.js']);
	assert.ok(s.notableCommands.some(c => c.includes('git commit')));
	assert.deepEqual(s.skills, ['superpowers:brainstorming']);
	assert.equal(s.errorCount, 1);
	assert.equal(s.subagents.length, 1);
	assert.ok(s.toolCounts.length >= 4);
});

test('toolUseLabel prefers the most identifying input field', () => {
	assert.match(toolUseLabel({ name: 'Bash', input: { command: 'ls -la' } }), /^Bash: ls -la/);
	assert.match(toolUseLabel({ name: 'Read', input: { file_path: '/x' } }), /^Read: \/x/);
	assert.equal(toolUseLabel({ name: 'Plain', input: {} }), 'Plain');
});

test('textFromContent tolerates strings, arrays, and junk', () => {
	assert.equal(textFromContent('a'), 'a');
	assert.equal(textFromContent([{ type: 'text', text: 'a' }, { type: 'tool_use' }]), 'a');
	assert.equal(textFromContent(null), '');
	assert.equal(textFromContent(42), '');
});

// The next three were all found by running the skill for real, not by unit testing.
test('harness interrupt markers are not treated as user prompts', () => {
	assert.equal(parseLine(userText('[Request interrupted by user]')), null);
	assert.equal(parseLine(userText('[Request interrupted by user for tool use]')), null);
	assert.ok(parseLine(userText('[Request] something I actually typed')), 'real text still kept');
});

test('a replayed prompt (mode switch) collapses, a genuine re-ask does not', () => {
	const dup = mergeConversation([
		parseLine(userText('do the thing')),
		parseLine(userText('do the thing')),   // /plan re-submitted it
	].filter(Boolean));
	assert.equal(dup.length, 1, 'consecutive identical prompts collapse');

	const reask = mergeConversation([
		parseLine(userText('do the thing')),
		parseLine(asst('working on it')),
		parseLine(userText('do the thing')),   // asked again after a reply — real
	].filter(Boolean));
	assert.equal(reask.filter(t => t.role === 'user').length, 2, 'a real re-ask is preserved');
});

// The exact real-world shape: /plan re-submits the pending prompt with the slash
// command appended, so the two records are NOT byte-identical.
test('samePrompt catches a replay that gained a trailing slash command', () => {
	const original = 'I need a new skill... trigger it with a session id and catch me up on that conversation';
	const replayed = original + '\n/plan';
	assert.ok(samePrompt(original, replayed), 'appended slash command must not defeat dedupe');
	assert.equal(promptKey(original), promptKey(replayed));

	// Guardrails: genuinely different prompts stay distinct, and short ones are not
	// collapsed by prefix-containment.
	assert.ok(!samePrompt(original, 'something else entirely'));
	assert.ok(!samePrompt('yes', 'yes please do that thing'), 'short prefixes must not collapse');
});

test('the compressed timeline dedupes a replayed prompt even across assistant turns', () => {
	// The real shape: prompt, work starts, /plan replays the prompt.
	const entries = [
		parseLine(userText('build me a thing with a long distinctive prompt body')),
		parseLine(asst('starting work')),
		parseLine(userText('build me a thing with a long distinctive prompt body')),
		parseLine(asst('continuing')),
	].filter(Boolean);
	// Pad so the early turns land in the compressed section rather than the window.
	for (let i = 0; i < 20; i++) entries.push(parseLine(asst('filler ' + i)));

	const data = {
		meta: { sessionId: 'abc', cwd: '/tmp', idleMs: 1000, liveness: 'idle', sizeBytes: 1000 },
		entries, signals: deriveSignals(entries),
	};
	const out = formatDigest(data, { window: 4 });
	const section = out.slice(out.indexOf('Your prompts in that stretch'), out.indexOf('Tool activity'));
	const hits = section.split('long distinctive prompt body').length - 1;
	assert.equal(hits, 1, `replayed prompt should appear once, appeared ${hits}x`);
});

test('notable commands show the interesting line, not a heredoc body', () => {
	const cmd = `cd /repo\ngit commit -q -F - <<'MSG'\nfeat: a very long commit subject line\n\nbody paragraph that should never appear in the digest\nMSG`;
	const out = notableLine(cmd);
	assert.match(out, /git commit/);
	assert.ok(!out.includes('body paragraph'), 'commit body must not leak');
	assert.ok(out.length <= 141, `too long: ${out.length}`);
});

test('parseLine survives malformed JSON', () => {
	assert.equal(parseLine('{not json'), null);
	assert.equal(parseLine(''), null);
});

test('digest respects --max-chars by shrinking detail then window', () => {
	const entries = [];
	for (let i = 0; i < 40; i++) {
		entries.push(parseLine(userText(`prompt ${i} ` + 'x'.repeat(3000))));
		entries.push(parseLine(asst(`reply ${i} ` + 'y'.repeat(3000))));
	}
	const data = {
		meta: { sessionId: 'abc', cwd: '/tmp', gitBranch: 'main', idleMs: 1000, liveness: 'active', sizeBytes: 500000, startedAt: base.timestamp },
		entries: entries.filter(Boolean),
		signals: deriveSignals(entries.filter(Boolean)),
	};
	// --max-chars is a HARD ceiling on the whole returned string, header included.
	for (const budget of [6000, 3000, 1500]) {
		const out = formatDigest(data, { maxChars: budget });
		assert.ok(out.length <= budget, `budget ${budget} exceeded: got ${out.length}`);
	}
	const small = formatDigest(data, { maxChars: 6000 });
	const big = formatDigest(data, { maxChars: 60000 });
	assert.ok(big.length > small.length, 'a larger budget yields more detail');
});

test('digest surfaces the blocked state prominently', () => {
	const entries = [parseLine(userText('go')), parseLine(asst('', [{ name: 'ExitPlanMode' }]))].filter(Boolean);
	const data = {
		meta: { sessionId: 'abc', cwd: '/tmp', idleMs: 1000, liveness: 'active', sizeBytes: 1000 },
		entries, signals: deriveSignals(entries),
	};
	assert.match(formatDigest(data), /BLOCKED ON YOU/);
});

test('describeFile reads identity from head/tail without a full parse', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'catchup-test-'));
	const f = path.join(dir, 'deadbeef-0000-0000-0000-000000000000.jsonl');
	const filler = Array.from({ length: 200 }, (_, i) => asst('filler ' + i + ' ' + 'z'.repeat(400))).join('\n');
	fs.writeFileSync(f, [
		J({ ...base, slug: 'my-slug', type: 'user', message: { role: 'user', content: 'hi' } }),
		filler,
		J({ type: 'custom-title', title: 'My Title', sessionId: 's1' }),
	].join('\n') + '\n');

	const rec = describeFile(f);
	assert.equal(rec.id, 'deadbeef-0000-0000-0000-000000000000');
	assert.equal(rec.cwd, '/tmp/proj');
	assert.equal(rec.slug, 'my-slug');
	assert.equal(rec.title, 'My Title', 'title found in the tail');
	fs.rmSync(dir, { recursive: true, force: true });
});

test('rankCandidates prefers exact cwd, then nearest path, then recency', () => {
	const c = [
		{ id: 'far', cwd: '/nowhere/else', mtimeMs: 9999 },
		{ id: 'exact', cwd: '/a/b/c', mtimeMs: 1 },
		{ id: 'near', cwd: '/a/b/other', mtimeMs: 5 },
	];
	assert.deepEqual(rankCandidates(c, '/a/b/c').map(x => x.id), ['exact', 'near', 'far']);
});

test('nudge ladder: full → protip → silent, and accepted goes silent', () => {
	const st = (over) => ({ runCount: 5, nudges: { hotline: { declines: 0, lastOfferedAt: null, accepted: false, ...over } } });
	assert.equal(decide(st({}), 'hotline'), 'full');
	assert.equal(decide(st({ declines: 1 }), 'hotline'), 'protip', 'runCount 5 is a protip tick');
	assert.equal(decide({ runCount: 4, nudges: { hotline: { declines: 1 } } }, 'hotline'), 'silent', 'off-tick is silent');
	assert.equal(decide(st({ declines: 2 }), 'hotline'), 'silent');
	assert.equal(decide(st({ accepted: true }), 'hotline'), 'silent');
	assert.equal(decide(st({ lastOfferedAt: new Date().toISOString() }), 'hotline'), 'silent', 'within 7 days');
	assert.equal(decide(st({ lastOfferedAt: '2020-01-01T00:00:00.000Z' }), 'hotline'), 'full', 'older than 7 days');
});
