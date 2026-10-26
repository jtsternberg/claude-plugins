// The critic's answer is the LAST ```json fence in its response: earlier fences may be
// the critic quoting the schema back.
export function lastJsonFence(text) {
  const re = /```json[^\n]*\n([\s\S]*?)```/g;
  let m, last = null;
  while ((m = re.exec(text ?? '')) !== null) last = m[1];
  return last;
}

const AB = ['A', 'B', 'tie'];

// Returns { ok: true, verdict } or { ok: false, reason }.
export function parseVerdict(text, spec) {
  const body = lastJsonFence(text);
  if (body === null) return { ok: false, reason: 'no ```json fence in the response' };
  let v;
  try { v = JSON.parse(body); } catch (e) { return { ok: false, reason: `json fence does not parse: ${e.message}` }; }
  if (v === null || typeof v !== 'object') return { ok: false, reason: 'verdict is not an object' };
  const ids = spec.criteria.map((c) => c.id);
  const conf = Number(v.confidence);
  if (!Number.isInteger(conf) || conf < 1 || conf > 5) return { ok: false, reason: 'confidence: must be an integer 1-5' };
  if (typeof v.biggest_gap !== 'string' || v.biggest_gap.trim() === '') return { ok: false, reason: 'biggest_gap: required' };

  if (spec.judge.mode === 'rubric') {
    const s = v.scores;
    if (!s || typeof s !== 'object') return { ok: false, reason: 'scores: required, {criterion: 1-10}' };
    for (const id of ids) {
      if (!Number.isInteger(s[id]) || s[id] < 1 || s[id] > 10) return { ok: false, reason: `scores.${id}: must be an integer 1-10` };
    }
    return { ok: true, verdict: { scores: pick(s, ids), biggest_gap: v.biggest_gap, confidence: conf } };
  }
  if (!AB.includes(v.winner)) return { ok: false, reason: 'winner: must be "A", "B" or "tie"' };
  const c = v.criteria;
  if (!c || typeof c !== 'object') return { ok: false, reason: 'criteria: required, {criterion: A|B|tie}' };
  for (const id of ids) if (!AB.includes(c[id])) return { ok: false, reason: `criteria.${id}: must be "A", "B" or "tie"` };
  return { ok: true, verdict: { winner: v.winner, criteria: pick(c, ids), biggest_gap: v.biggest_gap, confidence: conf } };
}

const pick = (o, ids) => Object.fromEntries(ids.map((id) => [id, o[id]]));

// One piece-round's passes (already unblinded) → the judged result.
// A rubric round wins when every criterion scores 7+ ("holds up next to the reference").
// A double pairwise round wins only when both passes agree; disagreement is a tie.
export function tally(passes, spec) {
  if (passes.some((p) => p.event === 'judge_error')) {
    return { result: 'error', reason: passes.find((p) => p.event === 'judge_error').reason };
  }
  const first = passes[0];
  const confidence = Math.round(passes.reduce((n, p) => n + p.confidence, 0) / passes.length);
  if (spec.judge.mode === 'rubric') {
    const won = Object.values(first.scores).every((n) => n >= 7);
    return { result: won ? 'won' : 'lost', scores: first.scores, biggest_gap: first.biggest_gap, confidence };
  }
  const winners = passes.map((p) => p.winner);
  const agreed = winners.every((x) => x === winners[0]);
  const w = agreed ? winners[0] : 'tie';
  const out = { result: w === 'ours' ? 'won' : w === 'ref' ? 'lost' : 'tie', criteria: first.criteria, biggest_gap: first.biggest_gap, confidence };
  if (passes.length > 1) out.swap_agreed = agreed;
  return out;
}
