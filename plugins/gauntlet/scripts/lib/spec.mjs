import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';

export const ID_RE = /^[a-z0-9][a-z0-9_-]*$/;
const RUN_ID_RE = /^[a-z0-9][a-z0-9._-]*$/;
const MEDIA = ['image', 'text', 'opaque'];
const MODES = ['blind-pairwise', 'rubric'];

export const DEFAULTS = {
  capture: { timeout_s: 120 },
  judge: { mode: 'blind-pairwise', prompt: null, model: null, double: false },
  builder: { model: null },
  budget: { max_rounds_per_piece: 12, max_rounds_total: 40, max_minutes: 180, call_timeout_s: 3600 },
  stop: { wins_to_close: 2, plateau_rounds: 3, smoothing_after_wave_changes: 2 },
  git: { branch: null, base: null, worktree: null, commit_captures: true },
};

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const nonEmpty = (v) => typeof v === 'string' && v.trim() !== '';

// Returns { spec, errors, notes }. `spec` has defaults applied; it is only safe to
// use when `errors` is empty. Every error names the field it is about.
export function validateSpec(raw) {
  const errors = [];
  const notes = [];
  if (!isObj(raw)) return { spec: null, errors: ['(root): must be a JSON object'], notes };
  const s = structuredClone(raw);
  for (const [k, d] of Object.entries(DEFAULTS)) {
    if (s[k] !== undefined && !isObj(s[k])) errors.push(`${k}: must be an object`);
    s[k] = { ...d, ...(isObj(s[k]) ? s[k] : {}) };
  }

  if (s.version !== 1) errors.push('version: must be 1');
  if (typeof s.run_id !== 'string' || !RUN_ID_RE.test(s.run_id)) errors.push('run_id: lowercase letters, digits, ".", "_" or "-", starting with a letter or digit');
  if (!nonEmpty(s.goal)) errors.push('goal: required, a non-empty string');

  if (!isObj(s.artifact)) errors.push('artifact: required, an object with "workspace"');
  else if (!nonEmpty(s.artifact.workspace) || !isAbsolute(s.artifact.workspace)) errors.push('artifact.workspace: required, an absolute path');

  if (!MEDIA.includes(s.medium)) errors.push(`medium: must be one of ${MEDIA.join(', ')}`);

  if (!nonEmpty(s.capture.command)) errors.push('capture.command: required, a shell command that writes one file to {out}');
  if (!nonEmpty(s.capture.ext) || !/^[a-z0-9]+$/i.test(s.capture.ext)) errors.push('capture.ext: required, a file extension without the dot (png, md, txt)');
  if (!Number.isInteger(s.capture.timeout_s) || s.capture.timeout_s < 1) errors.push('capture.timeout_s: must be a positive integer');

  if (!Array.isArray(s.bar) || s.bar.length === 0) errors.push('bar: required, at least one reference');
  else {
    const seen = new Set();
    s.bar.forEach((b, i) => {
      if (!isObj(b)) { errors.push(`bar[${i}]: must be an object`); return; }
      if (typeof b.id !== 'string' || !ID_RE.test(b.id)) errors.push(`bar[${i}].id: required, lowercase id`);
      else if (seen.has(b.id)) errors.push(`bar[${i}].id: duplicate "${b.id}"`);
      else seen.add(b.id);
      if (!nonEmpty(b.file) || isAbsolute(b.file)) errors.push(`bar[${i}].file: required, a path relative to the run dir (refs/<id>.<ext>)`);
    });
  }

  if (!Array.isArray(s.criteria) || s.criteria.length === 0) errors.push('criteria: required, at least one criterion');
  else {
    const seen = new Set();
    s.criteria.forEach((c, i) => {
      if (!isObj(c)) { errors.push(`criteria[${i}]: must be an object`); return; }
      if (typeof c.id !== 'string' || !ID_RE.test(c.id)) errors.push(`criteria[${i}].id: required, lowercase id`);
      else if (seen.has(c.id)) errors.push(`criteria[${i}].id: duplicate "${c.id}"`);
      else seen.add(c.id);
      if (!nonEmpty(c.ask)) errors.push(`criteria[${i}].ask: required, the question the critic answers`);
    });
  }

  if (s.split_hints !== undefined && !(Array.isArray(s.split_hints) && s.split_hints.every(nonEmpty))) errors.push('split_hints: must be an array of strings');

  if (!MODES.includes(s.judge.mode)) errors.push(`judge.mode: must be one of ${MODES.join(', ')}`);
  if (s.judge.prompt !== null && !nonEmpty(s.judge.prompt)) errors.push('judge.prompt: null (bundled template) or a template path');
  if (typeof s.judge.double !== 'boolean') errors.push('judge.double: must be true or false');
  for (const k of ['judge', 'builder']) {
    if (s[k].model !== null && !nonEmpty(s[k].model)) errors.push(`${k}.model: null (hotline default) or a model name`);
  }
  if (s.medium === 'opaque' && s.judge.mode !== 'rubric') {
    s.judge.mode = 'rubric';
    notes.push('medium "opaque" cannot be blinded, so judge.mode is forced to "rubric"');
  }

  for (const k of Object.keys(DEFAULTS.budget)) posInt(s.budget, 'budget', k, errors);
  for (const k of Object.keys(DEFAULTS.stop)) posInt(s.stop, 'stop', k, errors);

  for (const k of ['branch', 'base', 'worktree']) {
    if (s.git[k] !== null && !nonEmpty(s.git[k])) errors.push(`git.${k}: null (default) or a string`);
  }
  if (s.git.worktree && !isAbsolute(s.git.worktree)) errors.push('git.worktree: must be an absolute path');
  if (typeof s.git.commit_captures !== 'boolean') errors.push('git.commit_captures: must be true or false');
  if (errors.length === 0) {
    s.git.branch ??= `gauntlet/${s.run_id}`;
    s.git.worktree ??= `${s.artifact.workspace.replace(/\/+$/, '')}-gauntlet-${s.run_id}`;
  }
  return { spec: s, errors, notes };
}

function posInt(obj, group, key, errors) {
  if (!Number.isInteger(obj[key]) || obj[key] < 1) errors.push(`${group}.${key}: must be a positive integer`);
}

export function loadSpec(path) {
  let raw;
  try { raw = JSON.parse(readFileSync(path, 'utf8')); }
  catch (e) { return { spec: null, errors: [`(file): ${path}: ${e.message}`], notes: [] }; }
  return validateSpec(raw);
}
