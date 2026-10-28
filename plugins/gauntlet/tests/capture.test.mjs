import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { cli, events, initAndSplit, makeFixture, PLUGIN, scratch } from './helpers.mjs';

test('capture tokens are substituted shell-quoted, piece capture keys included', () => {
  const fx = makeFixture({ spec: { capture: { command: 'printf "%s|%s|%s" {piece} {round} {label} > {out}', ext: 'txt' }, budget: { max_rounds_total: 1 } } });
  initAndSplit(fx, [{ id: 'hero', capture: { label: "it's $HOME" } }]);
  cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(readFileSync(join(fx.runDir, events(fx, 'captured')[0].file), 'utf8'), "hero|1|it's $HOME");
});

test('a failing or empty capture is a capture_error, not a judgment', () => {
  for (const command of ['exit 7', 'true']) {
    const fx = makeFixture({ spec: { capture: { command, ext: 'txt' }, budget: { max_rounds_total: 1 } } });
    initAndSplit(fx);
    cli(fx, ['loop', '--run', fx.runDir]);
    assert.equal(events(fx, 'capture_error').length, 1, command);
    assert.equal(events(fx, 'verdict').length, 0);
  }
});

test('try-capture dry-runs the harness in the workspace', () => {
  const fx = makeFixture({ spec: { capture: { command: 'cat index.txt > {out}', ext: 'txt' } } });
  const r = cli(fx, ['try-capture', fx.specPath, '--piece', 'hero']);
  assert.equal(r.rc, 0, r.stdout);
  assert.equal(readFileSync(r.json.out, 'utf8').trim(), 'site');
});

test('the text reference harness copies one heading section', () => {
  const d = scratch();
  writeFileSync(join(d, 'doc.md'), '# Title\nintro\n## Install\nstep one\n### Detail\nmore\n## Usage\nlater\n');
  const r = spawnSync('node', [join(PLUGIN, 'references/capture-text.mjs'), '--file', join(d, 'doc.md'), '--heading', 'Install', '--out', join(d, 'o.md')], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(readFileSync(join(d, 'o.md'), 'utf8'), '## Install\nstep one\n### Detail\nmore\n');
});

test('the image reference harness refuses cleanly without playwright', () => {
  const d = scratch();
  const r = spawnSync('node', [join(PLUGIN, 'references/capture-image.mjs'), '--url', 'http://localhost:1/', '--out', join(d, 'o.png')], { cwd: d, encoding: 'utf8' });
  if (r.status === 3) assert.match(r.stderr, /playwright is not installed/);
  else assert.notEqual(r.status, 0, 'with playwright present, an unreachable URL still fails');
});

test('a raised budget in gauntlet.json is picked up mid-run', () => {
  const fx = makeFixture({ env: { FAKE_CRITIC: 'ref' }, spec: { budget: { max_rounds_total: 1 } } });
  initAndSplit(fx);
  assert.equal(cli(fx, ['loop', '--run', fx.runDir]).json.last.reason, 'budget:max_rounds_total');
  const p = join(fx.runDir, 'gauntlet.json');
  const s = JSON.parse(readFileSync(p, 'utf8'));
  s.budget.max_rounds_total = 2;
  writeFileSync(p, JSON.stringify(s));
  cli(fx, ['resume', '--run', fx.runDir]);
  cli(fx, ['loop', '--run', fx.runDir]);
  assert.equal(events(fx, 'built').length, 2);
});
