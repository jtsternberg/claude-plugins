#!/usr/bin/env node
// Generate the Codex-native marketplace catalog (.agents/plugins/marketplace.json).
//
// WHY THIS EXISTS: Codex CLI (0.147.0+) resolves marketplace `jtsternberg` to
// .agents/plugins/marketplace.json and never reads .claude-plugin/marketplace.json.
// A hand-authored native catalog silently drops any plugin it omits from Codex
// (bug claude-plugins-0way). So the native catalog is GENERATED, not authored:
// its inventory is the legacy Claude catalog verbatim, plus a deliberately small
// Codex policy overlay (scripts/codex-catalog.config.json). Codex reads each
// plugin's manifest by fallback — .codex-plugin/plugin.json if present, else
// .claude-plugin/plugin.json — so no per-plugin native manifests are required
// (verified live, codex-cli 0.147.0). See docs/codex/adr-002-marketplace-catalog.md.
//
// Usage:
//   node scripts/gen-codex-catalog.mjs            # write .agents/plugins/marketplace.json
//   node scripts/gen-codex-catalog.mjs --check     # verify committed output is current + invariants; exit 1 on drift

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = join(HERE, '..');
export const LEGACY_PATH = join(REPO_ROOT, '.claude-plugin', 'marketplace.json');
export const NATIVE_PATH = join(REPO_ROOT, '.agents', 'plugins', 'marketplace.json');
export const CONFIG_PATH = join(HERE, 'codex-catalog.config.json');

export function loadLegacy() {
  return JSON.parse(readFileSync(LEGACY_PATH, 'utf8'));
}

export function loadConfig() {
  return JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
}

// Build one native entry with a stable key order (name, source, category, policy)
// so serialize() is deterministic and --check can byte-compare.
function makeEntry(name, path, config) {
  const entry = {
    name,
    source: { source: 'local', path },
    category: config.categoryOverrides[name] || config.defaultCategory,
  };
  if (config.notAvailable.includes(name)) {
    entry.policy = { installation: 'NOT_AVAILABLE' };
  }
  return entry;
}

export function buildCatalog(legacy = loadLegacy(), config = loadConfig()) {
  const plugins = [];
  // 1. Legacy inventory, in legacy order. Legacy source is a bare string path.
  for (const p of legacy.plugins) {
    plugins.push(makeEntry(p.name, p.source, config));
  }
  // 2. Native-only extras (e.g. the `codex` plugin, absent from the legacy catalog).
  for (const extra of config.nativeOnly) {
    plugins.push(makeEntry(extra.name, extra.path, config));
  }
  return { ...config.header, plugins };
}

// Canonical serialization: 2-space indent + trailing newline (matches repo JSON style).
export function serialize(catalog) {
  return JSON.stringify(catalog, null, 2) + '\n';
}

// Returns { ok, errors[] }. Checks byte-equality with the committed file plus
// the three ADR-002 drift invariants.
export function check() {
  const legacy = loadLegacy();
  const config = loadConfig();
  const fresh = serialize(buildCatalog(legacy, config));
  const errors = [];

  let committed = null;
  try {
    committed = readFileSync(NATIVE_PATH, 'utf8');
  } catch {
    errors.push(`missing committed catalog at ${NATIVE_PATH}`);
  }

  if (committed !== null && committed !== fresh) {
    errors.push('committed native catalog differs from generated output — run: node scripts/gen-codex-catalog.mjs');
  }

  const catalog = JSON.parse(fresh);
  const byName = new Map(catalog.plugins.map((p) => [p.name, p]));

  // (1) every legacy name + source appears exactly once
  for (const p of legacy.plugins) {
    const e = byName.get(p.name);
    if (!e) errors.push(`legacy plugin "${p.name}" missing from native catalog`);
    else if (e.source.path !== p.source) errors.push(`source path mismatch for "${p.name}"`);
  }
  const counts = new Map();
  for (const p of catalog.plugins) counts.set(p.name, (counts.get(p.name) || 0) + 1);
  for (const [name, n] of counts) if (n !== 1) errors.push(`plugin "${name}" appears ${n} times`);

  // (2) only the declared notAvailable set carries policy
  const marked = catalog.plugins
    .filter((p) => p.policy && p.policy.installation === 'NOT_AVAILABLE')
    .map((p) => p.name)
    .sort();
  const expected = [...config.notAvailable].sort();
  if (JSON.stringify(marked) !== JSON.stringify(expected)) {
    errors.push(`NOT_AVAILABLE set is ${JSON.stringify(marked)}, expected ${JSON.stringify(expected)}`);
  }

  // (3) native-only extras present
  for (const extra of config.nativeOnly) {
    if (!byName.has(extra.name)) errors.push(`native-only extra "${extra.name}" missing`);
  }

  return { ok: errors.length === 0, errors };
}

function main() {
  const checkMode = process.argv.includes('--check');
  if (checkMode) {
    const { ok, errors } = check();
    if (!ok) {
      console.error('codex catalog drift check FAILED:');
      for (const e of errors) console.error(`  - ${e}`);
      process.exit(1);
    }
    console.log('codex catalog is up to date.');
    return;
  }
  const out = serialize(buildCatalog());
  writeFileSync(NATIVE_PATH, out);
  const n = JSON.parse(out).plugins.length;
  console.log(`wrote ${NATIVE_PATH} (${n} entries)`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
