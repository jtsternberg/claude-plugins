// =============================================================================
// tail-judge.mjs — ask a local tev1 model whether a session's closing message is
// waiting on the human, when deriveTailState's regexes said it is not.
//
// tev1 is a System One decision model: Ollama serves it only through the
// TypeSafe-compatible /v1/systemone endpoint (its sole capability is `decision`;
// /api/chat and /api/generate answer 400). One noul question returns P(yes).
//
// Used automatically whenever Ollama answers and has the model; otherwise the
// tail state passes through unchanged. Everything stays on this machine.
// SESSION_TOOLS_JUDGE=off disables it; SESSION_TOOLS_JUDGE_MODEL names another
// Ollama decision model. A model that is not in Ollama's list costs one fast read
// of that list and no decision call.
// =============================================================================

// tev1:4b, not 0.8b: on a 13-message labeled set (2026-10-13) 4b put every
// waiting message at >=0.74 and every finished one at <=0.27; 0.8b overlapped
// (waiting 0.25-0.91, finished 0.15-0.32) and scored real long closings ~0.4.
const MODEL = 'tev1:4b';
const QUESTION = 'Does `last_message` end by requesting a decision or input from the human (a question, a set of options to choose from, or a request for approval)?';

// Set from that same eval; a 13-case set, so the middle band is reported as a
// maybe rather than forced to one side.
export const BLOCKED_AT = 0.6;
export const MAYBE_AT = 0.35;

async function withTimeout(fetchImpl, url, init, ms) {
	const ac = new AbortController();
	const timer = setTimeout(() => ac.abort(), ms);
	try { return await fetchImpl(url, { ...init, signal: ac.signal }); }
	finally { clearTimeout(timer); }
}

/** Probability (0..1) that `text` is waiting on the human, or null when no judgment was possible. */
export async function askTev1(text, { url, fetchImpl = globalThis.fetch, model = process.env.SESSION_TOOLS_JUDGE_MODEL || MODEL, timeoutMs = 45000 } = {}) {
	// Loading tev1:4b cold took 38.8s (2026-10-13, another model unloading); a
	// loaded call takes ~0.15s. Waiting out the load is the point: a digest that
	// times out first never gets judged. --no-judge is the fast path.
	let base = url || process.env.OLLAMA_HOST || 'http://127.0.0.1:11434';
	if (!/^https?:\/\//.test(base)) base = `http://${base}`; // OLLAMA_HOST is often bare host:port
	base = base.replace(/\/$/, '');
	try {
		// A missing model must cost one local read, not a pull or a failed decision call.
		// 5s, not 500ms: on a loaded box (load avg 350+, 2026-10-13) this read alone
		// passed 500ms and the judge was silently skipped. Absent Ollama still fails
		// at once with a refused connection.
		const tags = await withTimeout(fetchImpl, `${base}/api/tags`, {}, 5000);
		if (!tags.ok) return null;
		const names = ((await tags.json()).models || []).map(m => m.name);
		if (!names.includes(model)) return null;

		const res = await withTimeout(fetchImpl, `${base}/v1/systemone`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				model,
				state: { last_message: text },
				questions: { waiting: { type: 'noul', instructions: QUESTION } },
			}),
		}, timeoutMs);
		if (!res.ok) return null;
		const p = (await res.json()).answers?.waiting?.noul;
		return typeof p === 'number' && p >= 0 && p <= 1 ? p : null;
	} catch {
		return null; // Ollama absent, slow cold start, unmounted model drive
	}
}

/** Re-judge an `idle-after-agent` tail; any other state is returned as-is. */
export async function judgeTail(tail, opts = {}) {
	if (process.env.SESSION_TOOLS_JUDGE === 'off') return tail;
	if (!tail || tail.state !== 'idle-after-agent' || !tail.closing) return tail;
	const p = await askTev1(tail.closing, opts);
	if (p === null) return tail;
	const pct = p.toFixed(2);
	if (p >= BLOCKED_AT) return { ...tail, state: 'blocked', detail: `tev1 read the last message as a question to you (p=${pct})`, question: tail.closing.slice(-300) };
	if (p >= MAYBE_AT) return { ...tail, state: 'maybe-blocked', detail: `tev1 could not tell whether the last message asks you something (p=${pct})`, question: tail.closing.slice(-300) };
	return tail;
}
