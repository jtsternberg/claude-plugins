import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const ledgerPath = (runDir) => join(runDir, 'ledger.jsonl');

export function readLedger(runDir) {
  const p = ledgerPath(runDir);
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8').split('\n').flatMap((line, i) => {
    if (line.trim() === '') return [];
    try { return [JSON.parse(line)]; }
    catch { throw new Error(`${p}:${i + 1}: not valid JSON; the ledger is append-only, so fix that line by hand`); }
  });
}

export function append(runDir, event, now = new Date()) {
  const e = { ts: now.toISOString(), ...event };
  appendFileSync(ledgerPath(runDir), JSON.stringify(e) + '\n');
  return e;
}
