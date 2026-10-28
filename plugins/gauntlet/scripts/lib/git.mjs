import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join, relative } from 'node:path';

export function git(cwd, args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  return { ok: r.status === 0, out: (r.stdout ?? '').trim(), err: (r.stderr ?? '').trim() };
}

function must(cwd, args) {
  const r = git(cwd, args);
  if (!r.ok) throw new Error(`git ${args.join(' ')}: ${r.err || r.out}`);
  return r.out;
}

export function createWorktree({ workspace, worktree, branch, base }) {
  must(workspace, ['rev-parse', '--show-toplevel']);
  const from = base || must(workspace, ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (existsSync(worktree)) throw new Error(`git.worktree ${worktree} already exists`);
  if (git(workspace, ['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`]).ok) throw new Error(`branch ${branch} already exists`);
  must(workspace, ['worktree', 'add', '-b', branch, worktree, from]);
  return from;
}

// Commits only the run dir, whatever else a builder left staged.
export function commitRunDir(worktree, runDir, subject, trailer) {
  const rel = relative(worktree, runDir);
  must(worktree, ['add', '-A', '--', rel]);
  if (git(worktree, ['diff', '--cached', '--quiet', '--', rel]).ok) return null;
  must(worktree, ['commit', '-q', '-m', subject, '--trailer', trailer, '--', rel]);
  return must(worktree, ['rev-parse', 'HEAD']);
}

export function commitWithTrailer(worktree, trailer) {
  const r = git(worktree, ['log', '-1', '--no-color', '--format=%H', '--fixed-strings', `--grep=${trailer}`]);
  return r.ok && r.out ? r.out : null;
}

export const isAncestor = (worktree, sha) => git(worktree, ['merge-base', '--is-ancestor', sha, 'HEAD']).ok;
export const head = (worktree) => git(worktree, ['rev-parse', '--short', 'HEAD']).out;

// One bd task per run, in the TARGET project's beads. No .beads/ or no bd → skip.
export function beadCreate(workspace, title, description) {
  if (!existsSync(join(workspace, '.beads'))) return null;
  const r = spawnSync('bd', ['create', title, '--description', description, '-t', 'task', '-p', '2', '--json'], { cwd: workspace, encoding: 'utf8' });
  if (r.status !== 0) return null;
  try { const j = JSON.parse(r.stdout); return (Array.isArray(j) ? j[0] : j)?.id ?? null; } catch { return null; }
}

export function beadClose(workspace, id, reason) {
  if (!id) return false;
  return spawnSync('bd', ['close', id, '--reason', reason, '--json'], { cwd: workspace, encoding: 'utf8' }).status === 0;
}
