import assert from 'node:assert/strict';
import { test } from 'node:test';
import { decide, fold } from '../scripts/lib/rules.mjs';
import { validateSpec } from '../scripts/lib/spec.mjs';

const T0 = Date.parse('2026-10-26T10:00:00Z');
const mkSpec = (over = {}) => validateSpec({
  version: 1, run_id: 'r', goal: 'g', artifact: { workspace: '/w' }, medium: 'text',
  capture: { command: 'x', ext: 'txt' }, bar: [{ id: 'a', file: 'refs/a.txt' }],
  criteria: [{ id: 'c', ask: '?' }], ...over,
}).spec;
const ctx = (over = {}) => ({ now: T0 + 60000, stopFile: false, isAncestor: () => true, ...over });
const base = (ids = ['hero']) => [
  { ts: new Date(T0).toISOString(), event: 'init', worktree: '/wt' },
  { event: 'split', pieces: ids.map((id) => ({ id })) },
];
// One full round of a piece in wave w: build, capture, judge.
const round = (piece, n, w, result) => [
  { event: 'built', piece, round: n, wave: w, commit: `c-${piece}-${n}` },
  { event: 'captured', piece, round: n, wave: w, file: `captures/${piece}/r${n}.txt` },
  { event: 'verdict', piece, round: n, wave: w, pass: 1 },
  { event: 'judged', piece, round: n, wave: w, result, biggest_gap: `gap ${n}` },
];
const wave = (w, builds, rechecks = []) => ({ event: 'wave', wave: w, builds, rechecks });
const next = (events, spec = mkSpec(), c = ctx()) => decide(fold(events, spec), spec, c);

test('no split yet → split; split → first wave', () => {
  assert.equal(next(base().slice(0, 1)).action, 'split');
  assert.deepEqual(next(base()), { action: 'wave', wave: 1, builds: ['hero'], rechecks: [] });
});

test('builds go one piece at a time, then all judges together', () => {
  const ev = [...base(['hero', 'cta']), wave(1, ['hero', 'cta'])];
  assert.equal(next(ev).piece, 'hero');
  ev.push({ event: 'built', piece: 'hero', round: 1, wave: 1, commit: 'c1' }, { event: 'captured', piece: 'hero', round: 1, wave: 1, file: 'f' });
  const a = next(ev);
  assert.equal(a.action, 'build');
  assert.equal(a.piece, 'cta');
  ev.push({ event: 'built', piece: 'cta', round: 1, wave: 1, commit: 'c2' }, { event: 'captured', piece: 'cta', round: 1, wave: 1, file: 'f' });
  const j = next(ev);
  assert.equal(j.action, 'judge');
  assert.deepEqual(j.pieces.map((p) => p.id), ['hero', 'cta']);
  assert.equal(j.passes, 1);
});

test('wins_to_close consecutive wins close a piece; the last gap is handed to the next build', () => {
  const ev = [...base(), wave(1, ['hero']), ...round('hero', 1, 1, 'won')];
  const st = fold(ev, mkSpec());
  assert.equal(st.pieces.get('hero').status, 'open');
  const b = next([...ev, wave(2, ['hero'])]);
  assert.equal(b.gap, 'gap 1');
  assert.equal(b.round, 2);
  ev.push(wave(2, ['hero']), ...round('hero', 2, 2, 'won'));
  assert.equal(fold(ev, mkSpec()).pieces.get('hero').status, 'closed');
});

test('a tie breaks the win streak', () => {
  const ev = [...base(), wave(1, ['hero']), ...round('hero', 1, 1, 'won'), wave(2, ['hero']), ...round('hero', 2, 2, 'tie'), wave(3, ['hero']), ...round('hero', 3, 3, 'won')];
  assert.equal(fold(ev, mkSpec()).pieces.get('hero').status, 'open');
});

test('plateau_rounds consecutive losses plateau a piece; all plateaued → stop', () => {
  const ev = [...base()];
  for (let i = 1; i <= 3; i++) ev.push(wave(i, ['hero']), ...round('hero', i, i, 'lost'));
  const st = fold(ev, mkSpec({ stop: { smoothing_after_wave_changes: 5 } }));
  assert.equal(st.pieces.get('hero').status, 'plateaued');
  assert.equal(st.pieces.get('hero').reason, 'plateau');
  assert.deepEqual(next(ev, mkSpec({ stop: { smoothing_after_wave_changes: 5 } })).action, 'smooth', 'final smooth before the stop');
  ev.push({ event: 'smoothed', wave: 3, commit: null });
  assert.deepEqual(next(ev), { action: 'stop', reason: 'plateau_all' });
});

test('max_rounds_per_piece caps a piece that keeps erroring', () => {
  const spec = mkSpec({ budget: { max_rounds_per_piece: 2 }, stop: { smoothing_after_wave_changes: 9 } });
  const ev = [...base(), wave(1, ['hero']), { event: 'build_error', piece: 'hero', round: 1, wave: 1 }, wave(2, ['hero']), { event: 'build_error', piece: 'hero', round: 2, wave: 2 }];
  const p = fold(ev, spec).pieces.get('hero');
  assert.equal(p.status, 'plateaued');
  assert.equal(p.reason, 'cap');
});

test('spend caps: max_rounds_total stops after the wave, max_minutes by wall clock', () => {
  const spec = mkSpec({ budget: { max_rounds_total: 1 }, stop: { smoothing_after_wave_changes: 9 } });
  const ev = [...base(['hero', 'cta']), wave(1, ['hero', 'cta']), { event: 'built', piece: 'hero', round: 1, wave: 1, commit: 'c' }, { event: 'captured', piece: 'hero', round: 1, wave: 1, file: 'f' }];
  assert.equal(next(ev, spec).action, 'judge', 'the in-flight wave is still judged');
  ev.push({ event: 'verdict', piece: 'hero', round: 1, wave: 1, pass: 1 }, { event: 'judged', piece: 'hero', round: 1, wave: 1, result: 'lost' });
  assert.deepEqual(next(ev, spec), { action: 'stop', reason: 'budget:max_rounds_total' });
  assert.deepEqual(next(base(), mkSpec({ budget: { max_minutes: 5 } }), ctx({ now: T0 + 6 * 60000 })), { action: 'stop', reason: 'budget:max_minutes' });
});

test('the STOP file wins over everything; a recorded stop stays stopped until resumed', () => {
  assert.deepEqual(next(base(), mkSpec(), ctx({ stopFile: true })), { action: 'stop', reason: 'human' });
  const ev = [...base(), { event: 'stopped', reason: 'budget:max_minutes' }];
  assert.equal(next(ev).recorded, true);
  ev.push({ event: 'resumed' });
  assert.equal(next(ev).action, 'wave');
});

test('a dispatched call with no completion is awaited; a paused one waits for resume', () => {
  const ev = [...base(), wave(1, ['hero']), { event: 'dispatched', role: 'builder', piece: 'hero', round: 1, wave: 1, call_dir: '/c1' }];
  assert.equal(next(ev).action, 'await');
  ev.push({ event: 'paused', call_dir: '/c1', wait_rc: 5 });
  assert.equal(next(ev).action, 'paused');
  ev.push({ event: 'resumed' });
  assert.equal(next(ev).action, 'await');
  ev.push({ event: 'built', piece: 'hero', round: 1, wave: 1, call_dir: '/c1', commit: 'c' });
  assert.equal(next(ev).action, 'judge', 'built but never captured is picked up by the judge step');
});

test('history rewritten: the last build commit is no longer an ancestor', () => {
  const ev = [...base(), wave(1, ['hero']), ...round('hero', 1, 1, 'lost'), wave(2, ['hero'])];
  assert.deepEqual(next(ev, mkSpec(), ctx({ isAncestor: () => false })), { action: 'stop', reason: 'history_rewritten' });
});

test('smoothing after a wave with enough changed pieces; a lost re-judge reopens the piece', () => {
  const spec = mkSpec({ stop: { wins_to_close: 1, smoothing_after_wave_changes: 2 } });
  const ev = [...base(['hero', 'cta']), wave(1, ['hero', 'cta']), ...round('hero', 1, 1, 'won'), ...round('cta', 1, 1, 'lost')];
  assert.deepEqual(next(ev, spec), { action: 'smooth', wave: 1, final: false });
  ev.push({ event: 'smoothed', wave: 1, commit: 's1' });
  assert.equal(fold(ev, spec).pieces.get('hero').status, 'recheck');
  const w = next(ev, spec);
  assert.deepEqual(w, { action: 'wave', wave: 2, builds: ['cta'], rechecks: ['hero'] });
  ev.push(wave(2, ['cta'], ['hero']), ...round('cta', 2, 2, 'won'));
  const j = next(ev, spec);
  assert.deepEqual(j.pieces, [{ id: 'hero', round: 1, recheck: true }]);
  ev.push({ event: 'captured', piece: 'hero', round: 1, wave: 2, recheck: true, file: 'f' }, { event: 'judged', piece: 'hero', round: 1, wave: 2, recheck: true, result: 'lost' });
  assert.equal(fold(ev, spec).pieces.get('hero').status, 'open');
  assert.equal(fold(ev, spec).pieces.get('hero').reason, 'reopened');
});

test('a smoother that commits nothing triggers no re-judges', () => {
  const spec = mkSpec({ stop: { wins_to_close: 1 } });
  const ev = [...base(), wave(1, ['hero']), ...round('hero', 1, 1, 'won')];
  assert.deepEqual(next(ev, spec), { action: 'smooth', wave: 1, final: true });
  ev.push({ event: 'smoothed', wave: 1, commit: null });
  assert.deepEqual(next(ev, spec), { action: 'stop', reason: 'all_closed' });
});

test('double judging asks for two passes', () => {
  const spec = mkSpec({ judge: { double: true } });
  const ev = [...base(), wave(1, ['hero']), { event: 'built', piece: 'hero', round: 1, wave: 1, commit: 'c' }, { event: 'captured', piece: 'hero', round: 1, wave: 1, file: 'f' }];
  assert.equal(next(ev, spec).passes, 2);
});
