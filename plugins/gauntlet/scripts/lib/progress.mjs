import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function show(runDir, rel, medium) {
  if (!rel) return '<p class="muted">no capture yet</p>';
  if (medium === 'image') return `<img src="${esc(rel)}" alt="${esc(rel)}">`;
  const abs = join(runDir, rel);
  if (medium === 'text' && existsSync(abs)) return `<pre>${esc(readFileSync(abs, 'utf8').slice(0, 4000))}</pre>`;
  return `<a href="${esc(rel)}">${esc(rel)}</a>`;
}

export function renderProgress(runDir, spec, st, extra = {}) {
  const refFile = (p) => (spec.bar.find((b) => b.id === p.def.ref) ?? spec.bar[0]).file;
  const rows = st.order.map((id) => {
    const p = st.pieces.get(id);
    return `<section>
  <h2>${esc(id)} <span class="tag ${esc(p.status)}">${esc(p.status)}</span></h2>
  <p>rounds ${p.rounds} · win streak ${p.wins} · loss streak ${p.losses} · last ${esc(p.lastResult ?? '—')}${p.reason ? ` · ${esc(p.reason)}` : ''}</p>
  ${p.lastGap ? `<p><b>Last gap:</b> ${esc(p.lastGap)}</p>` : ''}
  <div class="pair"><figure><figcaption>ours</figcaption>${show(runDir, p.lastCapture, spec.medium)}</figure>
  <figure><figcaption>reference</figcaption>${show(runDir, refFile(p), spec.medium)}</figure></div>
</section>`;
  }).join('\n');
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Gauntlet ${esc(spec.run_id)}</title>
<style>
:root{--bg:#fff;--fg:#1b1b1f;--muted:#6b6b76;--line:#e4e4ea;--won:#1f7a3d;--lost:#a12b2b}
@media (prefers-color-scheme:dark){:root{--bg:#141418;--fg:#ececf1;--muted:#9a9aa6;--line:#2c2c34;--won:#5fcf86;--lost:#f08080}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif;margin:0 auto;max-width:1100px;padding:16px}
section{border-top:1px solid var(--line);padding:12px 0}.muted,figcaption{color:var(--muted)}
.pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px}
figure{margin:0}img{max-width:100%;border:1px solid var(--line)}pre{white-space:pre-wrap;border:1px solid var(--line);padding:8px;max-height:400px;overflow:auto}
.tag{font-size:12px;border:1px solid var(--line);border-radius:4px;padding:1px 6px}.closed{color:var(--won)}.plateaued{color:var(--lost)}
</style></head><body>
<h1>Gauntlet: ${esc(spec.run_id)}</h1>
<p class="muted">${esc(spec.goal)}</p>
<p>wave ${st.wave} · ${st.totalRounds}/${spec.budget.max_rounds_total} rounds · branch ${esc(st.init?.branch)}${extra.next ? ` · next: ${esc(extra.next)}` : ''}${st.stopped ? ` · stopped: ${esc(st.stopped.reason)}` : ''}</p>
${rows || '<p class="muted">not split yet</p>'}
</body></html>
`;
  writeFileSync(join(runDir, 'progress.html'), html);
}
