import assert from 'node:assert/strict';
import { test } from 'node:test';
import { validateSpec } from '../scripts/lib/spec.mjs';

const good = () => ({
  version: 1, run_id: 'landing-1', goal: 'g', artifact: { workspace: '/tmp/site' }, medium: 'image',
  capture: { command: 'node cap.mjs --out {out}', ext: 'png' },
  bar: [{ id: 'ref-a', file: 'refs/ref-a.png' }], criteria: [{ id: 'clarity', ask: 'Which is clearer?' }],
});

test('a minimal spec validates and gets the documented defaults', () => {
  const { spec, errors } = validateSpec(good());
  assert.deepEqual(errors, []);
  assert.equal(spec.judge.mode, 'blind-pairwise');
  assert.equal(spec.judge.double, false);
  assert.equal(spec.stop.wins_to_close, 2);
  assert.equal(spec.stop.plateau_rounds, 3);
  assert.equal(spec.git.commit_captures, true);
  assert.equal(spec.git.branch, 'gauntlet/landing-1');
  assert.equal(spec.git.worktree, '/tmp/site-gauntlet-landing-1');
});

test('errors name the field they are about', () => {
  const s = good();
  delete s.goal;
  s.judge = { mode: 'vibes' };
  s.criteria.push({ id: 'clarity', ask: 'again' });
  s.artifact.workspace = 'relative/path';
  s.budget = { max_rounds_total: 0 };
  const { errors } = validateSpec(s);
  for (const field of ['goal:', 'judge.mode:', 'criteria[1].id: duplicate', 'artifact.workspace:', 'budget.max_rounds_total:']) {
    assert.ok(errors.some((e) => e.startsWith(field)), `expected an error for ${field}: ${errors.join(' | ')}`);
  }
});

test('opaque medium forces rubric and says so', () => {
  const { spec, errors, notes } = validateSpec({ ...good(), medium: 'opaque' });
  assert.deepEqual(errors, []);
  assert.equal(spec.judge.mode, 'rubric');
  assert.match(notes[0], /opaque/);
});

test('rubric is a user choice, never switched automatically', () => {
  assert.equal(validateSpec({ ...good(), judge: { mode: 'rubric' } }).spec.judge.mode, 'rubric');
  assert.equal(validateSpec({ ...good(), medium: 'text' }).spec.judge.mode, 'blind-pairwise');
});
