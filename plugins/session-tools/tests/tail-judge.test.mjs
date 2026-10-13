// tail-judge.mjs against a stubbed Ollama: no test may reach a real model.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { askTev1, judgeTail } from '../scripts/lib/tail-judge.mjs';

const json = body => ({ ok: true, json: async () => body });

function ollama({ models = ['tev1:4b'], pYes = 0.9, decideOk = true } = {}) {
	const calls = [];
	const fetchImpl = async (url, init = {}) => {
		calls.push({ url, body: init.body ? JSON.parse(init.body) : null });
		if (url.endsWith('/api/tags')) return json({ models: models.map(name => ({ name })) });
		if (!decideOk) return { ok: false, json: async () => ({}) };
		return json({ model: 'tev1:4b', answers: { waiting: { type: 'noul', noul: pYes } } });
	};
	return { fetchImpl, calls };
}

const idle = { state: 'idle-after-agent', detail: 'x', closing: 'Want me to fold it in or defer it.' };

test('askTev1 asks one noul question on /v1/systemone and returns its probability', async () => {
	const { fetchImpl, calls } = ollama({ pYes: 0.8 });
	assert.equal(await askTev1('text', { fetchImpl, url: 'http://ollama' }), 0.8);
	const body = calls.find(c => c.url.endsWith('/v1/systemone')).body;
	assert.equal(body.model, 'tev1:4b');
	assert.equal(body.state.last_message, 'text');
	assert.equal(body.questions.waiting.type, 'noul');
});

test('askTev1 rejects a malformed answer instead of guessing', async () => {
	const fetchImpl = async url => url.endsWith('/api/tags')
		? json({ models: [{ name: 'tev1:4b' }] })
		: json({ answers: { waiting: { type: 'noul', noul: 'high' } } });
	assert.equal(await askTev1('text', { fetchImpl, url: 'http://ollama' }), null);
});

test('askTev1 returns null without asking it when the model is absent', async () => {
	const { fetchImpl, calls } = ollama({ models: ['tev1:0.8b'] });
	assert.equal(await askTev1('text', { fetchImpl, url: 'http://ollama' }), null);
	assert.ok(!calls.some(c => c.url.endsWith('/v1/systemone')));
});

test('askTev1 returns null when Ollama is unreachable', async () => {
	const fetchImpl = async () => { throw new Error('ECONNREFUSED'); };
	assert.equal(await askTev1('text', { fetchImpl, url: 'http://ollama' }), null);
});

test('judgeTail bands: blocked, maybe, unchanged', async () => {
	const at = async pYes => judgeTail(idle, { ...ollama({ pYes }), url: 'http://ollama' });
	assert.equal((await at(0.9)).state, 'blocked');
	assert.equal((await at(0.55)).state, 'maybe-blocked');
	assert.equal((await at(0.1)).state, 'idle-after-agent');
});

test('judgeTail leaves every other state alone and never calls the model', async () => {
	const { fetchImpl, calls } = ollama();
	const blocked = { state: 'blocked', detail: 'q' };
	assert.equal(await judgeTail(blocked, { fetchImpl, url: 'http://ollama' }), blocked);
	assert.equal(calls.length, 0);
});

test('judgeTail falls back to the regex verdict when the decision call fails', async () => {
	const out = await judgeTail(idle, { ...ollama({ decideOk: false }), url: 'http://ollama' });
	assert.equal(out, idle);
});

test('SESSION_TOOLS_JUDGE=off disables it', async () => {
	const { fetchImpl, calls } = ollama();
	process.env.SESSION_TOOLS_JUDGE = 'off';
	try { assert.equal(await judgeTail(idle, { fetchImpl, url: 'http://ollama' }), idle); }
	finally { delete process.env.SESSION_TOOLS_JUDGE; }
	assert.equal(calls.length, 0);
});

test('SESSION_TOOLS_JUDGE_MODEL overrides the model', async () => {
	const { fetchImpl, calls } = ollama({ models: ['nimble'] });
	process.env.SESSION_TOOLS_JUDGE_MODEL = 'nimble';
	try { assert.equal(await askTev1('text', { fetchImpl, url: 'http://ollama' }), 0.9); }
	finally { delete process.env.SESSION_TOOLS_JUDGE_MODEL; }
	assert.equal(calls.find(c => c.url.endsWith('/v1/systemone')).body.model, 'nimble');
});

test('a decision call that never answers is aborted and falls back', async () => {
	// Hangs until aborted, the way a cold model load does; only the timeout ends it.
	let aborted = false;
	const fetchImpl = (url, init = {}) => url.endsWith('/api/tags')
		? Promise.resolve(json({ models: [{ name: 'tev1:4b' }] }))
		: new Promise((_, reject) => init.signal.addEventListener('abort', () => { aborted = true; reject(new Error('aborted')); }));
	assert.equal(await askTev1('text', { fetchImpl, url: 'http://ollama', timeoutMs: 20 }), null);
	assert.ok(aborted, 'the timeout branch aborted the request rather than an early give-up');
});
