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
import { describeFile, rankCandidates, resolve as resolveTarget } from '../scripts/lib/session-index.mjs';
import { formatDigest, formatMd } from '../scripts/lib/format.mjs';
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

// ---- archive fidelity (md) vs catch-up fidelity (digest) ----------------------
// A permanent archive must record what the session was ASKED to do and what its
// tools returned. The digest deliberately drops both. These pin the split.

const slashCmd = (name, args = '') => J({
	...base, type: 'user', uuid: 'c1',
	message: { role: 'user', content: `<command-name>${name}</command-name><command-message>${name.slice(1)}</command-message><command-args>${args}</command-args>` },
});

test('slash-command turns: dropped for catch-up, preserved as /foo args for archive', () => {
	const line = slashCmd('/fix-github-issue', '#2407');
	assert.equal(parseLine(line), null, 'digest fidelity drops the command envelope');

	const kept = parseLine(line, { archive: true });
	assert.ok(kept, 'archive fidelity keeps it');
	assert.equal(kept.role, 'user');
	assert.equal(kept.kind, 'command');
	assert.equal(kept.text, '/fix-github-issue #2407');
});

test('archive keeps a bare command with no args, and still drops harness boilerplate', () => {
	assert.equal(parseLine(slashCmd('/handoff:pickup-handoff'), { archive: true }).text, '/handoff:pickup-handoff');
	// isMeta / caveat lines are harness machinery in BOTH modes.
	assert.equal(parseLine(userText('ctx', { isMeta: true }), { archive: true }), null);
	assert.equal(parseLine(userText('Caveat: The messages below were generated while running local commands.'), { archive: true }), null);
});

test('archive keeps user interrupt markers; catch-up drops them', () => {
	const int = userText('[Request interrupted by user for tool use]');
	assert.equal(parseLine(int), null, 'not a prompt — noise on a catch-up card');
	const kept = parseLine(int, { archive: true });
	assert.ok(kept, 'an interruption IS history in an archive');
	assert.match(kept.text, /Request interrupted by user/);
});

test('tool output: body dropped for catch-up, clipped+kept for archive, keyed by tool_use_id', () => {
	const line = J({
		...base, type: 'user', uuid: 'tr9',
		message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't0', content: 'line1\nline2' }] },
	});
	assert.equal(parseLine(line).text, '', 'digest drops the body');

	const kept = parseLine(line, { archive: true });
	assert.equal(kept.toolUseId, 't0');
	assert.match(kept.text, /line1/);
	assert.match(kept.text, /line2/);
});

test('archive clips an oversized tool result and says how much it elided', () => {
	const huge = 'y'.repeat(9000);
	const kept = parseLine(J({
		...base, type: 'user', uuid: 'tr10',
		message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't0', content: huge }] },
	}), { archive: true });
	assert.ok(kept.text.length < 3000, `clipped, got ${kept.text.length}`);
	assert.match(kept.text, /elided/, 'the elision is disclosed, not silent');
});

test('mergeConversation attaches tool output to the tool call that produced it', () => {
	const entries = [
		parseLine(asst('running it', [{ name: 'Bash', input: { command: 'ls -la' } }]), { archive: true }),
		parseLine(J({
			...base, type: 'user', uuid: 'tr11',
			message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't0', content: 'file1\nfile2' }] },
		}), { archive: true }),
	].filter(Boolean);

	const plain = mergeConversation(entries);
	assert.equal(plain[0].toolUses[0].output, undefined, 'default merge leaves tool output off');

	const merged = mergeConversation(entries, { attachToolResults: true });
	assert.match(merged[0].toolUses[0].output, /file1/);
});

test('formatMd records the opening slash command and the tool output', () => {
	const entries = [
		parseLine(slashCmd('/visual-review', 'the plan'), { archive: true }),
		parseLine(asst('on it', [{ name: 'Bash', input: { command: 'git status' } }]), { archive: true }),
		parseLine(J({
			...base, type: 'user', uuid: 'tr12',
			message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't0', content: 'nothing to commit' }] },
		}), { archive: true }),
	].filter(Boolean);
	const md = formatMd({ meta: { sessionId: 's1', cwd: '/tmp/proj' }, entries });

	assert.match(md, /\/visual-review the plan/, 'the archive must say what was asked');
	assert.match(md, /nothing to commit/, 'and what came back');
});

test('formatMd keeps every tool call; the digest is the one that caps at 8', () => {
	const many = Array.from({ length: 11 }, (_, i) => ({ name: 'Bash', input: { command: `step-${i}` } }));
	const entries = [parseLine(asst('many steps', many), { archive: true })];
	const md = formatMd({ meta: { sessionId: 's1' }, entries });
	assert.match(md, /step-10/, 'no +N more elision in a full transcript');
	assert.doesNotMatch(md, /more$/m);
});

test('digest output is unchanged by archive support (fast path regression guard)', () => {
	const entries = [
		parseLine(slashCmd('/fix-github-issue', '#2407')),
		parseLine(userText('now do the thing')),
		parseLine(asst('done', [{ name: 'Bash', input: { command: 'ls' } }])),
	].filter(Boolean);
	const digest = formatDigest({
		meta: { sessionId: 's1', cwd: '/tmp/proj', sizeBytes: 1000, idleMs: 1000, liveness: 'active' },
		entries, signals: deriveSignals(entries),
	});
	assert.doesNotMatch(digest, /fix-github-issue/, 'command turns stay out of the digest');
	assert.match(digest, /now do the thing/);
});

// Second shape of a slash command in the wild: a client-side command (/model,
// /clear) lands as type:"system" subtype:"local_command", envelope in a TOP-LEVEL
// content field, isMeta:true. Found by sweeping 40 real sessions — 2 of 36
// command-bearing ones recorded their command only this way.
test('archive records local_command system records too', () => {
	const line = J({
		...base, type: 'system', subtype: 'local_command', isMeta: true, uuid: 'sc1',
		content: '<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>claude-opus-5</command-args>',
	});
	assert.equal(parseLine(line), null, 'a client-side setting change is noise on a catch-up card');
	const kept = parseLine(line, { archive: true });
	assert.ok(kept, 'but it is something the user did, so the archive keeps it');
	assert.equal(kept.kind, 'command');
	assert.equal(kept.text, '/model claude-opus-5');
});

test('archive still drops system records that carry no command', () => {
	assert.equal(parseLine(J({ ...base, type: 'system', subtype: 'turn_duration', content: 'took 4s' }), { archive: true }), null);
	assert.equal(parseLine(J({ ...base, type: 'system', subtype: 'stop_hook_summary' }), { archive: true }), null);
});

// A caller that already holds a transcript path (bulk scanners like the weekly
// recap) should not have to reverse it into a session id just to be resolved.
test('resolve accepts a direct transcript path', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'catchup-path-'));
	const f = path.join(dir, 'abcdef01-0000-0000-0000-000000000000.jsonl');
	fs.writeFileSync(f, userText('hello from a path') + '\n');
	try {
		assert.equal(resolveTarget(f).file, f);
		assert.equal(resolveTarget(f).how, 'path');
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});
