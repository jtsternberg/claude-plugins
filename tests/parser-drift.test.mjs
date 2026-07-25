// =============================================================================
// Repo-level drift guard for the transcript parser.
//
// Run: node --test tests/parser-drift.test.mjs
//
// WHY THIS EXISTS
// lib/transcript.mjs is the source of truth for reading Claude Code transcripts.
// switchboard's server.js carries its own Node copy of that logic because it
// predates the consolidation, and the two MUST agree about what is harness noise
// and what a compaction boundary looks like. They did not: server.js shipped
// missing <local-command-caveat> and <task-notification> (so the live dashboard
// rendered them as conversation) and detected compaction only via the long-dead
// type:"summary" record (so no modern session showed a boundary, and the summary
// rendered as though the user had typed it). Both were found by hand. This test
// is what finds the next one.
//
// SCOPE — deliberately two implementations, not four.
// The other readers named in transcript.mjs's header are NOT vendored copies of
// this contract and are excluded on purpose:
//   - hotline/skills/dial/scripts/transcript-extract.sh (jq) strips no harness
//     noise whatsoever; it filters isSidechain and nothing else. It is slated for
//     retirement, so the fix is to finish that, not to hold it to this contract.
//   - sessions-weekly-recap/scripts/extract_sessions.py uses a generic
//     strip-all-tags regex and filters neither isMeta, isSidechain, nor
//     compaction. Different strategy, different (narrower) job.
// Asserting a shared contract over those two would fail on day one for reasons
// that are not drift. Holding the two that genuinely must match is the useful
// test; the rest is tracked as its own work.
// =============================================================================

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { parseTranscript } from '../plugins/session-tools/skills/sessions-catch-up/scripts/lib/transcript.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SERVER = path.join(REPO, 'plugins/hotline/skills/switchboard/scripts/server.js');

// Every shape that has actually caused a divergence, plus the ones most likely to.
const SID = 'dr1f7000-0000-4000-8000-000000000001';
const J = (o) => JSON.stringify(o);
const base = { sessionId: SID, cwd: '/tmp/drift-ws', timestamp: '2026-07-25T10:00:00.000Z' };

const FIXTURE = [
	J({ ...base, type: 'user', message: { role: 'user', content: '<system-reminder>INJECTED</system-reminder>prose one' } }),
	J({ ...base, type: 'user', message: { role: 'user', content: '<local-command-caveat>CAVEAT</local-command-caveat>prose two' } }),
	J({ ...base, type: 'user', message: { role: 'user', content: '<task-notification>NOTIFY</task-notification>prose three' } }),
	J({ ...base, type: 'user', message: { role: 'user', content: '<local-command-stdout>STDOUT</local-command-stdout>prose four' } }),
	J({ ...base, type: 'user', message: { role: 'user', content: '<command-message>MESSAGE</command-message>prose five' } }),
	J({ ...base, type: 'user', isCompactSummary: true, message: { role: 'user', content: 'COMPACTION BOUNDARY TEXT' } }),
	J({ ...base, type: 'user', message: { role: 'user', content: 'prose after compaction' } }),
	J({ ...base, type: 'assistant', isSidechain: true, message: { role: 'assistant', content: [{ type: 'text', text: 'SUBAGENT' }] } }),
	J({ ...base, type: 'user', isMeta: true, message: { role: 'user', content: 'META' } }),
	J({ ...base, type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'assistant prose' }] } }),
].join('\n') + '\n';

// Text that must never survive into rendered conversation, in ANY implementation.
const MUST_NOT_LEAK = ['INJECTED', 'CAVEAT', 'NOTIFY', 'STDOUT', 'MESSAGE', 'SUBAGENT', 'META',
	'system-reminder', 'local-command-caveat', 'task-notification', 'command-message'];
// Prose that must survive alongside the noise it was mixed with.
const MUST_SURVIVE = ['prose one', 'prose two', 'prose three', 'prose four', 'prose five'];

function sandbox() {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'parser-drift-'));
	const projects = path.join(dir, 'projects', '-tmp-drift-ws');
	fs.mkdirSync(projects, { recursive: true });
	fs.mkdirSync(path.join(dir, 'sessions'), { recursive: true });
	const file = path.join(projects, `${SID}.jsonl`);
	fs.writeFileSync(file, FIXTURE);
	return { dir, file, projectsRoot: path.join(dir, 'projects'), sessionsDir: path.join(dir, 'sessions') };
}

/** Boot switchboard's server and read the fixture back through its own parser. */
async function viaSwitchboard(sb) {
	const port = 42000 + Number(process.hrtime.bigint() % 2000n);
	const proc = spawn('node', [SERVER, `--port=${port}`], {
		env: { ...process.env, HOTLINE_SESSIONS_DIR: sb.sessionsDir, HOTLINE_PROJECTS_ROOT: sb.projectsRoot },
		stdio: 'ignore',
	});
	try {
		const url = `http://127.0.0.1:${port}/api/transcript?session=${SID}`;
		for (let i = 0; i < 60; i++) {
			try {
				const r = await fetch(url);
				if (r.ok) return await r.json();
			} catch { /* not up yet */ }
			await new Promise(res => setTimeout(res, 100));
		}
		throw new Error('switchboard server did not come up');
	} finally {
		proc.kill('SIGKILL');
	}
}

test('transcript.mjs and switchboard agree: no harness noise leaks, prose survives', async () => {
	const sb = sandbox();
	try {
		const mine = parseTranscript(sb.file).entries.map(e => e.text || '').join('\n');
		const theirs = (await viaSwitchboard(sb)).entries.map(e => e.text || '').join('\n');

		for (const [name, text] of [['transcript.mjs', mine], ['switchboard', theirs]]) {
			for (const leak of MUST_NOT_LEAK) {
				assert.ok(!text.includes(leak), `${name} leaked '${leak}' — the two parsers have drifted`);
			}
			for (const keep of MUST_SURVIVE) {
				assert.ok(text.includes(keep), `${name} dropped '${keep}' along with the noise around it`);
			}
		}
	} finally {
		fs.rmSync(sb.dir, { recursive: true, force: true });
	}
});

test('transcript.mjs and switchboard agree: compaction is a boundary, not a user turn', async () => {
	const sb = sandbox();
	try {
		const mine = parseTranscript(sb.file).entries;
		const theirs = (await viaSwitchboard(sb)).entries;

		const mineHit = mine.find(e => (e.text || '').includes('COMPACTION BOUNDARY TEXT'));
		assert.ok(mineHit, 'transcript.mjs lost the compaction summary');
		assert.equal(mineHit.kind, 'compaction');
		assert.equal(mineHit.role, 'system');

		const theirsHit = theirs.find(e => (e.text || '').includes('COMPACTION BOUNDARY TEXT'));
		assert.ok(theirsHit, 'switchboard lost the compaction summary');
		assert.equal(theirsHit.role, 'system', 'a compaction summary rendered as a user turn reads as though the user typed it');
		assert.equal(theirsHit.kind, 'summary');

		// And the turn after the boundary is still an ordinary user turn in both.
		for (const [name, entries] of [['transcript.mjs', mine], ['switchboard', theirs]]) {
			const after = entries.find(e => (e.text || '').includes('prose after compaction'));
			assert.ok(after, `${name} dropped the turn after the compaction boundary`);
			assert.equal(after.role, 'user', name);
		}
	} finally {
		fs.rmSync(sb.dir, { recursive: true, force: true });
	}
});
