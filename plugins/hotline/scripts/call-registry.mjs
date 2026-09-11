#!/usr/bin/env node
// =============================================================================
// Hotline Call Registry: the one reader for ~/.agents-hotline/sessions/*.json
// By Justin Sternberg <me@jtsternberg.com>
//
// Shared by the switchboard server and the call-status skill so the two can
// never disagree about what an entry means. Strictly read-only: it opens
// registry files and nothing else.
//
// Usage as a module:
//   import { readRegistry, defaultSessionsDir } from '<plugin>/scripts/call-registry.mjs';
//   const records = readRegistry(defaultSessionsDir());
//
// Usage as a CLI (one JSON object per line, newest-agnostic order):
//   node call-registry.mjs [sessions-dir]
//
// Registry shape is written by skills/dial/scripts/session-cache.sh; consult its
// header for what each connection field means and why surface_ref is opaque.
// =============================================================================

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export function defaultSessionsDir() {
  return process.env.HOTLINE_SESSIONS_DIR || path.join(os.homedir(), '.agents-hotline', 'sessions');
}

/**
 * Read every call recorded in a registry directory.
 *
 * One record per CALLEE — a caller file holds one connection per target, so a
 * caller that dialed three workspaces yields three records.
 *
 * @param {string} sessionsDir Registry directory to read.
 * @param {{warn?: (message: string) => void}} [options] `warn` receives one
 *   message per skipped file; defaults to a stderr line.
 * @returns {Array<object>} Records in registry-filename order.
 */
export function readRegistry(sessionsDir, options = {}) {
  const warn = options.warn || ((message) => console.error(`call-registry: ${message}`));
  let files;
  try {
    files = fs.readdirSync(sessionsDir).filter((f) => f.endsWith('.json')).sort();
  } catch {
    // No registry directory yet is the normal state before the first dial.
    return [];
  }

  const records = [];
  for (const f of files) {
    let reg;
    try {
      reg = JSON.parse(fs.readFileSync(path.join(sessionsDir, f), 'utf8'));
    } catch (err) {
      // A half-written or hand-edited file must cost only itself: the caller is
      // usually after the OTHER entries.
      warn(`skipping ${f}: ${err.message}`);
      continue;
    }

    // Legacy entries predate caller_session_id. The filename has always been the
    // caller's session id, so it is a fallback rather than a guess.
    const callerSessionId = (reg && reg.caller_session_id) || path.basename(f, '.json');
    const callerPath = (reg && reg.caller) || '';
    const connections = (reg && reg.connections) || {};

    for (const [target, conn] of Object.entries(connections)) {
      if (!conn || typeof conn !== 'object') {
        warn(`skipping ${f} connection ${target}: not an object`);
        continue;
      }
      records.push({
        caller_session_id: callerSessionId,
        caller_path: callerPath,
        target,
        callee_session_id: conn.session_id || '',
        mode: conn.mode || 'unknown',
        started: conn.started || 0,
        last_contact: conn.last_contact || 0,
        exchange_count: conn.exchange_count || 0,
        // surface_ref is the opaque HOST HANDLE; transport/remote say which
        // backend and which box it belongs to. All three are absent on entries
        // written before hotline 0.31.0 and on headless calls.
        host_handle: conn.surface_ref || '',
        transport: conn.transport || '',
        remote: conn.remote || '',
      });
    }
  }
  return records;
}

const invokedDirectly = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (invokedDirectly) {
  const dir = process.argv[2] || defaultSessionsDir();
  for (const record of readRegistry(dir)) {
    process.stdout.write(`${JSON.stringify(record)}\n`);
  }
}
