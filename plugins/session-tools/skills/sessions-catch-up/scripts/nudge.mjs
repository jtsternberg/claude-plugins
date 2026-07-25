#!/usr/bin/env node
// =============================================================================
// nudge.mjs — offer-backoff ledger, so optional enhancements never nag.
//
// The skill can offer three things: install `hotline` (to reply into the target
// session), write a `handoff` doc, or install the `claude-session-catchup` shell
// wrapper. Each offer is useful once and annoying forever after, so the decision
// lives here rather than in SKILL.md prose that an agent has to re-reason about.
//
// Escalation ladder per offer kind:
//   0 declines → "full"   (a real offer, at most once per 7 days)
//   1 decline  → "protip" (a one-line footer, at most every 5th run)
//  2+ declines → "silent" (never again)
//   accepted   → "silent" (it is installed; stop mentioning it)
//
// Usage:
//   nudge.mjs bump                      # once per skill invocation
//   nudge.mjs check <kind>              # → full | protip | silent
//   nudge.mjs record <kind> accepted|declined
//   nudge.mjs show                      # dump the ledger
// =============================================================================

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const PREFS = path.join(os.homedir(), '.claude', 'sessions-catch-up.prefs.json');
const KINDS = new Set(['hotline', 'handoff', 'wrapper']);
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const PROTIP_EVERY = 5;

function load() {
	try { return JSON.parse(fs.readFileSync(PREFS, 'utf8')); }
	catch { return { runCount: 0, nudges: {} }; }
}

function save(state) {
	try {
		fs.mkdirSync(path.dirname(PREFS), { recursive: true });
		fs.writeFileSync(PREFS, JSON.stringify(state, null, 2));
	} catch { /* preferences are best-effort */ }
}

function entry(state, kind) {
	state.nudges[kind] ||= { declines: 0, lastOfferedAt: null, accepted: false };
	return state.nudges[kind];
}

export function decide(state, kind) {
	const e = entry(state, kind);
	if (e.accepted) return 'silent';
	if (e.declines >= 2) return 'silent';
	if (e.declines === 1) return (state.runCount % PROTIP_EVERY === 0) ? 'protip' : 'silent';
	if (e.lastOfferedAt && (Date.now() - Date.parse(e.lastOfferedAt)) < WEEK_MS) return 'silent';
	return 'full';
}

function main() {
	const [cmd, kind, outcome] = process.argv.slice(2);
	const state = load();

	if (cmd === 'bump') {
		state.runCount = (state.runCount || 0) + 1;
		save(state);
		process.stdout.write(String(state.runCount) + '\n');
		return;
	}

	if (cmd === 'show') {
		process.stdout.write(JSON.stringify(state, null, 2) + '\n');
		return;
	}

	if (cmd === 'check') {
		if (!KINDS.has(kind)) { process.stderr.write(`unknown kind '${kind}'\n`); process.exit(1); }
		const verdict = decide(state, kind);
		if (verdict !== 'silent') { entry(state, kind).lastOfferedAt = new Date().toISOString(); save(state); }
		process.stdout.write(verdict + '\n');
		return;
	}

	if (cmd === 'record') {
		if (!KINDS.has(kind)) { process.stderr.write(`unknown kind '${kind}'\n`); process.exit(1); }
		const e = entry(state, kind);
		if (outcome === 'accepted') e.accepted = true;
		else if (outcome === 'declined') e.declines = (e.declines || 0) + 1;
		else { process.stderr.write("outcome must be 'accepted' or 'declined'\n"); process.exit(1); }
		save(state);
		process.stdout.write('ok\n');
		return;
	}

	process.stderr.write('usage: nudge.mjs bump | check <kind> | record <kind> accepted|declined | show\n');
	process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
