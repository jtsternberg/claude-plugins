#!/usr/bin/env python3
import argparse
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

HOME = Path.home()
SCRIPTS = Path(__file__).resolve().parents[3] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from real_codex import real_codex  # noqa: E402
UUID = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')

class Refusal(Exception):
    pass

class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal(message)

def t3_rows():
    db = HOME / '.t3/userdata/statev2.sqlite'
    if not db.exists():
        return []
    try:
        with closing(sqlite3.connect(f'file:{db}?mode=ro', uri=True)) as conn:
            rows = conn.execute('select thread_id, payload_json from orchestration_v2_projection_provider_threads').fetchall()
        result = []
        for thread, payload in rows:
            data = json.loads(payload)
            ref = data.get('nativeThreadRef') if isinstance(data, dict) else None
            if not isinstance(ref, dict) or 'nativeId' not in ref:
                raise ValueError('nativeThreadRef.nativeId field missing')
            result.append((thread.removeprefix('thread_'), ref['nativeId']))
        return result
    except (sqlite3.Error, ValueError, TypeError) as exc:
        raise Refusal(f'T3 ownership lookup unavailable: {exc}') from exc

def unique(matches, description):
    if len(matches) > 1:
        raise Refusal(f'ambiguous {description}: {matches}')
    return matches[0] if matches else None

def claude_config_dirs():
    # The list's one definition is claude-config-dirs.sh, shared with dial and the switchboard.
    proc = subprocess.run(['bash', str(SCRIPTS / 'claude-config-dirs.sh')], capture_output=True, text=True, check=True, env={**os.environ, 'HOME': str(HOME)})
    return [Path(d) for d in proc.stdout.splitlines() if d]

def resolve(ref):
    rows = t3_rows()
    tid = ref.removeprefix('thread_')
    match = unique([t for t, _ in rows if t == tid], 'T3 thread')
    if match:
        return ('t3', match, None)
    if ref.startswith('thread_'):
        raise Refusal(f'no T3 thread matches {ref}; candidates: []')
    match = unique([t for t, native in rows if native == ref], 'T3 native ID')
    if match:
        return ('t3', match, None)
    sessions = []
    for config in claude_config_dirs():
        for path in (config / 'sessions').glob('*.json'):
            try:
                data = json.loads(path.read_text())
                if ref in (str(data.get('pid')), data.get('name'), data.get('sessionId')):
                    sessions.append((data, config))
            except (OSError, ValueError):
                continue
    match = unique(sessions, 'Claude sessions')
    if match:
        session, _ = match
        if not session.get('messagingSocketPath') or not session.get('cwd') or not session.get('sessionId'):
            raise Refusal('Claude registry entry lacks socket, cwd or session ID')
        return ('claude', session['sessionId'], match)
    if UUID.fullmatch(ref):
        cmd = 'source "$1/codex-rollout.sh"; source "$1/codex-home.sh"; codex_home_autodetect "$2"; rc=$?; printf "%s\\n%s\\n" "$HOTLINE_CODEX_HOME" "$CODEX_HOME_ERR"; exit "$rc"'
        proc = subprocess.run(['bash', '-c', cmd, 'send', str(SCRIPTS), ref], capture_output=True, text=True, env={k:v for k,v in os.environ.items() if k not in ('HOTLINE_CODEX_HOME','HOTLINE_HERDR_REMOTE')})
        lines = proc.stdout.splitlines()
        if proc.returncode:
            raise Refusal((lines[1] if len(lines) > 1 and lines[1] else f'no target matches {ref}; candidates: []'))
        home = Path(lines[0])
        rollouts = list((home / 'sessions').rglob(f'rollout-*-{ref}.jsonl'))
        rollout = unique([str(p) for p in rollouts], 'Codex rollouts')
        if rollout:
            return ('codex', ref, (home, Path(rollout)))
    raise Refusal(f'no target matches {ref}; candidates: []')

def transcript(session, config):
    proc = subprocess.run(['bash', '-c', 'source "$1/transcript-confirm.sh"; hotline_transcript_candidates "$2" "$3"', 'send', str(SCRIPTS), session['cwd'], session['sessionId']], capture_output=True, text=True, check=True, env={**os.environ, 'HOTLINE_CLAUDE_CONFIG_DIR': str(config)})
    return [Path(p) for p in proc.stdout.splitlines()]

def snapshot(paths):
    return {p: p.stat().st_size if p.exists() else 0 for p in paths}

def verify(paths, offsets, nonce, timeout, claude=False):
    deadline = time.monotonic() + timeout
    while True:
        for path in paths:
            try:
                with path.open('rb') as f:
                    f.seek(offsets[path]); data = f.read().decode('utf-8', 'replace')
                for line in data.splitlines():
                    try: row = json.loads(line)
                    except ValueError: continue
                    if claude and row.get('type') == 'system':
                        content = row.get('content', '')
                        if isinstance(content, str) and 'held peer message' in content.lower():
                            preview = re.search(r'preview:\s*«(.*?)»', content, re.DOTALL)
                            if preview and nonce in preview.group(1):
                                return 'held', str(path)
                    if nonce in line and (not claude or row.get('type') in ('user', 'queue-operation')):
                        return 'delivered', str(path)
            except OSError:
                pass
        if time.monotonic() >= deadline:
            return 'unconfirmed', 'no matching receiver transcript evidence'
        time.sleep(min(.2, max(0, deadline - time.monotonic())))

# The sender's own "You should know" notes ride along on its outgoing message: a
# long-lived callee reports through send, not through the caller's waiter, so its
# notes would otherwise never leave its unwatched terminal. The reader is the one in
# scripts/you-should-know.sh (its header has the quiet/broken rules). Everything here
# is best-effort: any failure means the message goes out exactly as it would without
# this, and a message with nothing to relay is byte-identical to one sent before it.
YSK_READER = SCRIPTS / 'you-should-know.sh'
SAFE_ID = re.compile(r'^[A-Za-z0-9_-]{1,128}$')

def ysk_dir():
    return Path(os.getenv('HOTLINE_YSK_SEND_DIR') or HOME / '.agents-hotline/you-should-know')

def ysk_locked(path, fn):
    # flock with a bounded wait: a lock we cannot get skips the cursor work rather
    # than holding up the send. Skipping an advance only risks a duplicate later.
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'a') as lock:
        for _ in range(20):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                time.sleep(.05)
        else:
            return None
        try: return fn()
        finally: fcntl.flock(lock, fcntl.LOCK_UN)

def ysk_write(path, text):
    tmp = path.with_name(f'{path.name}.tmp.{os.getpid()}')
    try:
        tmp.write_text(text); os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)

def ysk_cursor(path):
    try: value = path.read_text().strip()
    except FileNotFoundError: return None
    return int(value) if value.isdigit() else None

def ysk_sender(sender_id):
    # Only a sender found in a Claude registry is a Claude session; the entry also
    # names its account (the store's config dir) and cwd (its transcript, which the
    # reader's canary counts check opportunities in).
    if not sender_id or not SAFE_ID.fullmatch(sender_id):
        return None
    for config in claude_config_dirs():
        for path in (config / 'sessions').glob('*.json'):
            try: data = json.loads(path.read_text())
            except (OSError, ValueError): continue
            if isinstance(data, dict) and data.get('sessionId') == sender_id:
                return config, data.get('cwd')
    return None

def ysk_run(cmd, env, deadline):
    # Its own process group, killed whole at the deadline: the reader's jq children
    # would otherwise hold the output pipe open and the send would wait them out.
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, 9); proc.communicate()
        raise
    if proc.returncode:
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return out

def ysk_collect(sender_id):
    """→ None (nothing to add), or (suffix, max shownAt carried or None)."""
    found = ysk_sender(sender_id)
    if not found:
        return None
    config, cwd = found
    base = ysk_dir()
    cursor_file, notes_file = base / f'{sender_id}.since', base / f'{sender_id}.jsonl'
    def seed():
        # First send from this sender: notes it was shown before now are history,
        # not news, so start the cursor here and relay nothing this time.
        since = ysk_cursor(cursor_file)
        if since is None:
            ysk_write(cursor_file, f'{int(time.time() * 1000)}\n')
        return since
    since = ysk_locked(base / f'{sender_id}.lock', seed)
    if since is None:
        return None
    env = {**os.environ, 'HOME': str(HOME)}
    deadline = time.monotonic() + float(os.getenv('HOTLINE_YSK_SEND_TIMEOUT') or 5)
    cmd = ['bash', str(YSK_READER), '--session', sender_id, '--since', str(since), '--config-dir', str(config)]
    if cwd:
        tp = ysk_run(['bash', str(SCRIPTS / 'transcript-path.sh'), '--cwd', cwd, '--session', sender_id], {**env, 'HOTLINE_CLAUDE_CONFIG_DIR': str(config)}, deadline)
        if tp.strip():
            cmd += ['--transcript', tp.strip()]
    out = json.loads(ysk_run(cmd, env, deadline))
    notes = [n for n in out['notes'] if isinstance(n, dict) and isinstance(n.get('line'), str)
             and isinstance(n.get('shownAt'), (int, float)) and n['shownAt'] > since]
    broken = out.get('broken')
    if not notes and not isinstance(broken, str):
        return None
    lines = []
    if notes:
        def keep():
            # The full notes (explanation, shownAt) stay sender-side; the message
            # carries one line each and this path. Rewritten whole through a rename,
            # deduped, so a retried send does not grow it.
            kept, seen = [], set()
            try: old = notes_file.read_text().splitlines()
            except FileNotFoundError: old = []
            for raw in old:
                try: n = json.loads(raw)
                except ValueError: continue
                if isinstance(n, dict): kept.append(n)
            kept += notes
            out = []
            for n in kept:
                key = (n.get('shownAt'), n.get('line'))
                if key not in seen: seen.add(key); out.append(json.dumps(n))
            ysk_write(notes_file, '\n'.join(out) + '\n')
            return True
        if not ysk_locked(base / f'{sender_id}.lock', keep):
            return None
        lines.append(f"Sender's You-should-know notes (full text: {notes_file}):")
        lines += [f"{one_line(n.get('tag') or 'You should know')}: {one_line(n['line'])}" for n in notes]
    if isinstance(broken, str):
        lines.append(f'Sender-side note relay: {one_line(broken)}')
    return '\n\n' + '\n'.join(lines), (max(n['shownAt'] for n in notes) if notes else None)

def one_line(text):
    return ' '.join(str(text).split())

def ysk_advance(sender_id, shown_at):
    cursor_file = ysk_dir() / f'{sender_id}.since'
    def advance():
        current = ysk_cursor(cursor_file)
        if current is None or shown_at > current:
            ysk_write(cursor_file, f'{int(shown_at)}\n')
    ysk_locked(ysk_dir() / f'{sender_id}.lock', advance)

def main():
    parser = JsonParser()
    parser.add_argument('target'); parser.add_argument('message')
    parser.add_argument('--sender-id', default=os.getenv('T3CODE_THREAD_ID') or os.getenv('CLAUDE_CODE_SESSION_ID') or os.getenv('CODEX_THREAD_ID'))
    parser.add_argument('--sender-name', default=os.getenv('HOTLINE_SENDER_NAME', 'agent'))
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--attest-mode', choices=('bypass', 'prompting'), help='opt in to asserting sender permission class to Claude')
    args = parser.parse_args()
    if not args.sender_id or not args.sender_name.strip() or args.timeout < 0 or not args.message.strip():
        raise Refusal('sender ID, sender name, nonempty message and nonnegative timeout are required')
    rows = t3_rows()
    sender = args.sender_id.removeprefix('thread_')
    hosted = unique([t for t, native in rows if native == sender or t == sender], 'sender T3 thread')
    if hosted: sender = 'thread_' + hosted
    route, target, detail = resolve(args.target)
    nonce = 'm-' + uuid.uuid4().hex[:16]
    ysk = None
    if not hosted:
        try: ysk = ysk_collect(args.sender_id)
        except Exception: ysk = None
    message = f'{nonce} [{args.sender_name}]\n{args.message}{ysk[0] if ysk else ""}\n\nReply: hotline send {sender} …\nMessage ID: {nonce}'
    evidence = ''
    if route == 't3':
        proc = subprocess.run(['t3', 'thread', 'send', target, '-'], input=message, capture_output=True, text=True)
        if proc.returncode: raise Refusal(f't3 send failed: {proc.stderr.strip()}')
        status, evidence = 'sent', proc.stdout.strip()
    elif route == 'claude':
        session, config = detail
        paths = transcript(session, config); offsets = snapshot(paths)
        frame = {'type':'user', 'message':{'role':'user', 'content':message}, 'priority':'next', 'msg_id':nonce}
        if args.attest_mode: frame['fromMode'] = args.attest_mode
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5); sock.connect(session['messagingSocketPath']); sock.sendall((json.dumps(frame)+'\n').encode())
        status, evidence = verify(paths, offsets, nonce, args.timeout, True)
    else:
        home, path = detail; paths = [path]; offsets = snapshot(paths)
        try: codex = real_codex()
        except ValueError as exc: raise Refusal(str(exc))
        proc = subprocess.run([codex,'queue','--thread',target,'--message',message], env={**os.environ, 'CODEX_HOME':str(home)}, capture_output=True, text=True)
        if proc.returncode: raise Refusal(f'codex queue failed: {proc.stderr.strip()}')
        status, evidence = verify(paths, offsets, nonce, args.timeout)
    # Only receiver transcript evidence moves the cursor: a held, unconfirmed or
    # merely accepted (T3 `sent`) message carries the same notes again next time.
    if ysk and ysk[1] is not None and status == 'delivered':
        try: ysk_advance(args.sender_id, ysk[1])
        except Exception: pass
    print(json.dumps({'status':status, 'route':route, 'target':target, 'evidence':evidence}))

if __name__ == '__main__':
    try: main()
    except (Refusal, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({'status':'error', 'route':None, 'target':None, 'evidence':str(exc)})); sys.exit(1)
