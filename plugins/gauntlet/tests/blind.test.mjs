import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { blind, discard, oursLabel, unblind } from '../scripts/lib/blind.mjs';
import { validateSpec } from '../scripts/lib/spec.mjs';
import { scratch } from './helpers.mjs';
import { lastJsonFence, parseVerdict, tally } from '../scripts/lib/verdict.mjs';

const src = scratch();
writeFileSync(join(src, 'ours.txt'), '  OURS body \n\n');
writeFileSync(join(src, 'ref.txt'), 'REF body');
const mk = (extra = {}) => blind({ ours: join(src, 'ours.txt'), ref: join(src, 'ref.txt'), ext: 'txt', medium: 'text', mode: 'blind-pairwise', seed: 'run:hero:1:1', ...extra });

test('the seeded assignment is deterministic and pass 2 swaps it', () => {
  assert.equal(oursLabel('s1'), oursLabel('s1'));
  assert.notEqual(oursLabel('s1', 1), oursLabel('s1', 2));
  const seen = new Set(Array.from({ length: 32 }, (_, i) => oursLabel(`seed-${i}`)));
  assert.deepEqual([...seen].sort(), ['A', 'B']);
});

test('the blind dir holds exactly A and B; the key sits outside it, outside any repo', () => {
  const b = mk();
  assert.deepEqual(readdirSync(b.dir).sort(), ['A.txt', 'B.txt']);
  assert.ok(existsSync(join(b.base, 'key.json')));
  assert.equal(dirname(b.dir), b.base);
  assert.notEqual(spawnSync('git', ['rev-parse', '--git-dir'], { cwd: b.dir }).status, 0, 'blind dir must not be inside a git repo');
  const key = JSON.parse(readFileSync(join(b.base, 'key.json'), 'utf8'));
  assert.equal(readFileSync(join(b.dir, `${key.ours}.txt`), 'utf8'), 'OURS body\n', 'text is whitespace-trimmed, nothing else');
  discard(b.base);
  assert.ok(!existsSync(b.base));
});

test('unblind maps A/B back to ours/ref, including the swapped pass', () => {
  for (const pass of [1, 2]) {
    const b = mk({ pass });
    const o = JSON.parse(readFileSync(join(b.base, 'key.json'), 'utf8')).ours;
    const r = o === 'A' ? 'B' : 'A';
    const v = unblind(b.base, { winner: o, criteria: { clarity: r, cta: 'tie' }, biggest_gap: 'x', confidence: 3 });
    assert.equal(v.winner, 'ours');
    assert.deepEqual(v.criteria, { clarity: 'ref', cta: 'tie' });
    assert.equal(v.biggest_gap, `[${o === 'A' ? 'A = ours, B = reference' : 'A = reference, B = ours'}] x`, 'the gap carries its key');
    discard(b.base);
  }
});

test('rubric blinding labels the pair instead', () => {
  const b = mk({ mode: 'rubric' });
  assert.deepEqual(readdirSync(b.dir).sort(), ['candidate.txt', 'reference.txt']);
  discard(b.base);
});

const spec = validateSpec({
  version: 1, run_id: 'r', goal: 'g', artifact: { workspace: '/w' }, medium: 'text',
  capture: { command: 'x', ext: 'txt' }, bar: [{ id: 'a', file: 'refs/a.txt' }],
  criteria: [{ id: 'clarity', ask: '?' }, { id: 'cta', ask: '?' }],
}).spec;

test('the verdict is the LAST json fence', () => {
  const text = 'schema:\n```json\n{"winner":"A|B|tie"}\n```\nanswer:\n```json\n{"winner":"B","criteria":{"clarity":"B","cta":"A"},"biggest_gap":"g","confidence":4}\n```\nSTATUS: WORK_COMPLETE';
  assert.match(lastJsonFence(text), /"winner":"B"/);
  const r = parseVerdict(text, spec);
  assert.ok(r.ok, r.reason);
  assert.equal(r.verdict.winner, 'B');
});

test('malformed verdicts say why', () => {
  assert.match(parseVerdict('no fence', spec).reason, /no ```json fence/);
  assert.match(parseVerdict('```json\n{"winner":"A","criteria":{"clarity":"A"},"biggest_gap":"g","confidence":4}\n```', spec).reason, /criteria\.cta/);
  assert.match(parseVerdict('```json\n{"winner":"A","criteria":{"clarity":"A","cta":"A"},"biggest_gap":"g","confidence":9}\n```', spec).reason, /confidence/);
});

test('tally: double passes must agree to win; rubric wins at 7+ everywhere', () => {
  const p = (winner) => ({ event: 'verdict', winner, criteria: {}, biggest_gap: 'g', confidence: 4 });
  assert.equal(tally([p('ours'), p('ours')], spec).result, 'won');
  assert.equal(tally([p('ours'), p('ref')], spec).result, 'tie');
  assert.equal(tally([p('ours'), p('ref')], spec).swap_agreed, false);
  assert.equal(tally([p('ref')], spec).result, 'lost');
  assert.equal(tally([{ event: 'judge_error', reason: 'x' }], spec).result, 'error');
  const rubric = { ...spec, judge: { ...spec.judge, mode: 'rubric' } };
  assert.equal(tally([{ event: 'verdict', scores: { clarity: 7, cta: 8 }, biggest_gap: 'g', confidence: 3 }], rubric).result, 'won');
  assert.equal(tally([{ event: 'verdict', scores: { clarity: 6, cta: 9 }, biggest_gap: 'g', confidence: 3 }], rubric).result, 'lost');
});
