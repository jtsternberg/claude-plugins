import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

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
//   <base>/prompt.md
// The mapping goes to keyFile, in the run dir (.gauntlet/<run>/keys/): nothing under
// <base> says which side is ours.
export function blind({ ours, ref, ext, medium, mode, seed, pass = 1, keyFile }) {
  const base = mkdtempSync(join(tmpdir(), 'gauntlet-'));
  const dir = join(base, 'blind');
  mkdirSync(dir);
  if (mode === 'rubric') {
    const files = { reference: `reference.${ext}`, candidate: `candidate.${ext}` };
    place(ref, join(dir, files.reference), medium);
    place(ours, join(dir, files.candidate), medium);
    writeKey(keyFile, { mode });
    return { base, dir, files, keyFile };
  }
  const o = oursLabel(seed, pass);
  const r = o === 'A' ? 'B' : 'A';
  place(ours, join(dir, `${o}.${ext}`), medium);
  place(ref, join(dir, `${r}.${ext}`), medium);
  writeKey(keyFile, { mode, ours: o, seed, pass });
  return { base, dir, keyFile, files: { A: `A.${ext}`, B: `B.${ext}` } };
}

function writeKey(keyFile, key) {
  mkdirSync(dirname(keyFile), { recursive: true });
  writeFileSync(keyFile, JSON.stringify(key));
}

const side = (v, o) => (v === 'tie' ? 'tie' : v === o ? 'ours' : 'ref');

// Maps a pairwise verdict's A/B back to ours/ref. Rubric verdicts pass through.
// The gap is free prose ("B's CTA…", "A stronger hero…"), so it is keyed rather than
// rewritten: replacing letters in prose would corrupt the article "A".
export function unblind(keyFile, verdict) {
  const key = JSON.parse(readFileSync(keyFile, 'utf8'));
  if (key.mode === 'rubric') return { ...verdict };
  const criteria = Object.fromEntries(Object.entries(verdict.criteria).map(([k, v]) => [k, side(v, key.ours)]));
  const legend = key.ours === 'A' ? 'A = ours, B = reference' : 'A = reference, B = ours';
  return { ...verdict, ours: key.ours, winner: side(verdict.winner, key.ours), criteria, biggest_gap: `[${legend}] ${verdict.biggest_gap}` };
}

export function discard(base) {
  if (base) rmSync(base, { recursive: true, force: true });
}
