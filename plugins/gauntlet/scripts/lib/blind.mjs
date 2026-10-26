import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Deterministic per (run, piece, round): a resumed run re-blinds the same way, and
// pass 2 of a double judgment is pass 1 swapped.
export function oursLabel(seed, pass = 1) {
  const bit = createHash('sha256').update(seed).digest()[0] & 1;
  const first = bit ? 'A' : 'B';
  return pass === 2 ? (first === 'A' ? 'B' : 'A') : first;
}

function place(src, dst, medium) {
  if (medium === 'text') writeFileSync(dst, readFileSync(src, 'utf8').trim() + '\n');
  else copyFileSync(src, dst);
}

// Layout under a fresh $TMPDIR dir, never inside a repo:
//   <base>/blind/   the critic's cwd and target: A.<ext>, B.<ext> (or the rubric pair)
//   <base>/key.json the mapping, outside the dir the critic is pointed at
//   <base>/prompt.md
export function blind({ ours, ref, ext, medium, mode, seed, pass = 1 }) {
  const base = mkdtempSync(join(tmpdir(), 'gauntlet-'));
  const dir = join(base, 'blind');
  mkdirSync(dir);
  if (mode === 'rubric') {
    const files = { reference: `reference.${ext}`, candidate: `candidate.${ext}` };
    place(ref, join(dir, files.reference), medium);
    place(ours, join(dir, files.candidate), medium);
    writeFileSync(join(base, 'key.json'), JSON.stringify({ mode }));
    return { base, dir, files };
  }
  const o = oursLabel(seed, pass);
  const r = o === 'A' ? 'B' : 'A';
  place(ours, join(dir, `${o}.${ext}`), medium);
  place(ref, join(dir, `${r}.${ext}`), medium);
  writeFileSync(join(base, 'key.json'), JSON.stringify({ mode, ours: o, seed, pass }));
  return { base, dir, files: { A: `A.${ext}`, B: `B.${ext}` } };
}

const side = (v, o) => (v === 'tie' ? 'tie' : v === o ? 'ours' : 'ref');

// Maps a pairwise verdict's A/B back to ours/ref. Rubric verdicts pass through.
export function unblind(base, verdict) {
  const key = JSON.parse(readFileSync(join(base, 'key.json'), 'utf8'));
  if (key.mode === 'rubric') return { ...verdict };
  const criteria = Object.fromEntries(Object.entries(verdict.criteria).map(([k, v]) => [k, side(v, key.ours)]));
  return { ...verdict, ours: key.ours, winner: side(verdict.winner, key.ours), criteria };
}

export function discard(base) {
  if (base) rmSync(base, { recursive: true, force: true });
}
