#!/usr/bin/env node
// Reference text harness: copy one markdown section (a heading and everything under
// it, up to the next heading of the same or higher level) to a file.
//   node capture.mjs --file <doc.md> [--heading "<exact heading text>"] --out <file.md>
// No --heading copies the whole file.
import { readFileSync, writeFileSync } from 'node:fs';
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]]] : acc), []));
if (!args.file || !args.out) { console.error('capture: --file and --out are required'); process.exit(2); }
const lines = readFileSync(args.file, 'utf8').split('\n');
let out = lines;
if (args.heading) {
  const start = lines.findIndex((l) => /^#{1,6} /.test(l) && l.replace(/^#+ /, '').trim() === args.heading);
  if (start < 0) { console.error(`capture: no heading "${args.heading}" in ${args.file}`); process.exit(1); }
  const level = lines[start].match(/^#+/)[0].length;
  const rel = lines.slice(start + 1).findIndex((l) => { const m = l.match(/^(#{1,6}) /); return m && m[1].length <= level; });
  out = lines.slice(start, rel < 0 ? undefined : start + 1 + rel);
}
writeFileSync(args.out, out.join('\n').trim() + '\n');
