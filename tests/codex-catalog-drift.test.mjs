// Drift guard for the generated Codex-native marketplace catalog.
//
// `.agents/plugins/marketplace.json` is OUTPUT, not a hand-authored file: it is
// emitted by scripts/gen-codex-catalog.mjs from the legacy Claude catalog
// (.claude-plugin/marketplace.json — the single inventory source of truth) plus
// the small policy overlay in scripts/codex-catalog.config.json. A hand-edit to
// the native catalog, a plugin added to the legacy catalog but not regenerated,
// or a drifted policy override all fail here. Regenerate with:
//     node scripts/gen-codex-catalog.mjs
//
// This mirrors tests/parser-drift.test.mjs: a repo-root suite, registered by an
// explicit `run` line in tests/run-all.sh (repo-root tests are NOT glob-discovered).
// ADR: docs/codex/adr-002-marketplace-catalog.md.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  REPO_ROOT,
  LEGACY_PATH,
  NATIVE_PATH,
  loadConfig,
  loadLegacy,
  buildCatalog,
  serialize,
} from '../scripts/gen-codex-catalog.mjs';

const committed = readFileSync(NATIVE_PATH, 'utf8');
const config = loadConfig();
const legacy = loadLegacy();
const native = JSON.parse(committed);

test('committed native catalog is byte-identical to freshly generated output (no drift)', () => {
  const fresh = serialize(buildCatalog());
  assert.equal(
    fresh,
    committed,
    'Native catalog is out of date. Run: node scripts/gen-codex-catalog.mjs',
  );
});

test('every legacy plugin appears exactly once in the native catalog with a matching source path', () => {
  const nativeByName = new Map(native.plugins.map((p) => [p.name, p]));
  for (const legacyEntry of legacy.plugins) {
    const nativeEntry = nativeByName.get(legacyEntry.name);
    assert.ok(nativeEntry, `legacy plugin "${legacyEntry.name}" missing from native catalog`);
    assert.equal(
      nativeEntry.source.path,
      legacyEntry.source,
      `source path mismatch for "${legacyEntry.name}"`,
    );
  }
  // exactly once each
  const counts = new Map();
  for (const p of native.plugins) counts.set(p.name, (counts.get(p.name) || 0) + 1);
  for (const [name, n] of counts) {
    assert.equal(n, 1, `plugin "${name}" appears ${n} times in native catalog`);
  }
});

test('native catalog inventory = legacy entries + declared native-only extras', () => {
  const expected = legacy.plugins.length + config.nativeOnly.length;
  assert.equal(native.plugins.length, expected, `expected ${expected} native entries`);
  for (const extra of config.nativeOnly) {
    const entry = native.plugins.find((p) => p.name === extra.name);
    assert.ok(entry, `native-only extra "${extra.name}" missing from native catalog`);
    assert.equal(entry.source.path, extra.path, `native-only "${extra.name}" wrong source path`);
  }
});

test('the only NOT_AVAILABLE overrides are exactly the declared set', () => {
  const marked = native.plugins
    .filter((p) => p.policy && p.policy.installation === 'NOT_AVAILABLE')
    .map((p) => p.name)
    .sort();
  assert.deepEqual(marked, [...config.notAvailable].sort());
  // and no entry carries any other policy shape
  for (const p of native.plugins) {
    if (p.policy) {
      assert.deepEqual(
        Object.keys(p.policy),
        ['installation'],
        `plugin "${p.name}" has an unexpected policy shape`,
      );
      assert.equal(p.policy.installation, 'NOT_AVAILABLE');
    }
  }
});
