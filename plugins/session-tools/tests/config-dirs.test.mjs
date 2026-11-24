// Transcripts are looked up across Claude config dirs: $CLAUDE_CONFIG_DIR
// (default ~/.claude), then each dir in $AGENT_CLAUDE_CONFIG_DIRS. Fake dirs in
// a temp HOME; the real environment's values are saved and restored.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { projectsRoots } from '../scripts/lib/transcript.mjs';
import { resolve, AmbiguousTarget } from '../scripts/lib/session-index.mjs';

const VARS = ['HOME', 'CLAUDE_CONFIG_DIR', 'AGENT_CLAUDE_CONFIG_DIRS'];

function sandbox(t) {
	const saved = Object.fromEntries(VARS.map(v => [v, process.env[v]]));
	t.after(() => {
		for (const v of VARS) {
			if (saved[v] === undefined) delete process.env[v]; else process.env[v] = saved[v];
		}
	});
	const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'st-cfgdirs-')));
	t.after(() => fs.rmSync(home, { recursive: true, force: true }));
	process.env.HOME = home;
	delete process.env.CLAUDE_CONFIG_DIR;
	delete process.env.AGENT_CLAUDE_CONFIG_DIRS;
	return home;
}

function transcript(configDir, id) {
	const dir = path.join(configDir, 'projects', '-tmp-ws');
	fs.mkdirSync(dir, { recursive: true });
	const file = path.join(dir, `${id}.jsonl`);
	fs.writeFileSync(file, JSON.stringify({ type: 'user', cwd: '/tmp/ws', sessionId: id }) + '\n');
	return file;
}

test('roots: default, CLAUDE_CONFIG_DIR replaces it, extras follow, dupes and empties drop', (t) => {
	const home = sandbox(t);
	assert.deepEqual(projectsRoots(), [path.join(home, '.claude', 'projects')]);
	fs.mkdirSync(path.join(home, 'alt'));
	fs.symlinkSync(path.join(home, 'alt'), path.join(home, 'alt-link'));
	process.env.CLAUDE_CONFIG_DIR = path.join(home, 'custom');
	process.env.AGENT_CLAUDE_CONFIG_DIRS = `${home}/alt::${home}/alt-link:${home}/custom/`;
	assert.deepEqual(projectsRoots(), [path.join(home, 'custom', 'projects'), path.join(home, 'alt', 'projects')]);
});

test('roots: a projects/ symlinked to another dir\'s is one root', (t) => {
	const home = sandbox(t);
	fs.mkdirSync(path.join(home, '.claude', 'projects'), { recursive: true });
	fs.mkdirSync(path.join(home, '.claude-alt'));
	fs.symlinkSync(path.join(home, '.claude', 'projects'), path.join(home, '.claude-alt', 'projects'));
	process.env.AGENT_CLAUDE_CONFIG_DIRS = path.join(home, '.claude-alt');
	assert.deepEqual(projectsRoots(), [path.join(home, '.claude', 'projects')]);
});

test('resolve finds a session whose transcript lives in an extra dir', (t) => {
	const home = sandbox(t);
	const id = 'abcdef01-1111-2222-3333-444444444444';
	const file = transcript(path.join(home, '.claude-alt'), id);
	assert.throws(() => resolve(id));
	process.env.AGENT_CLAUDE_CONFIG_DIRS = path.join(home, '.claude-alt');
	assert.equal(resolve(id).file, file);
});

test('resolve refuses an id with transcripts in two distinct dirs', (t) => {
	const home = sandbox(t);
	const id = 'abcdef02-1111-2222-3333-444444444444';
	transcript(path.join(home, '.claude'), id);
	transcript(path.join(home, '.claude-alt'), id);
	process.env.AGENT_CLAUDE_CONFIG_DIRS = path.join(home, '.claude-alt');
	assert.throws(() => resolve(id), AmbiguousTarget);
});
