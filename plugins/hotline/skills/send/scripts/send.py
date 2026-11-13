#!/usr/bin/env python3
import argparse
from contextlib import closing
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

def resolve(ref):
    rows = t3_rows()
    tid = ref.removeprefix('thread_')
    if ref.startswith('thread_') or UUID.fullmatch(tid):
        match = unique([t for t, _ in rows if t == tid], 'T3 thread')
        if match:
            return ('t3', match, None)
        if ref.startswith('thread_'):
            raise Refusal(f'no T3 thread matches {ref}; candidates: []')
    match = unique([t for t, native in rows if native == ref], 'T3 native ID')
    if match:
        return ('t3', match, None)
    sessions = []
    for path in (HOME / '.claude/sessions').glob('*.json'):
        try:
            data = json.loads(path.read_text())
            if ref in (str(data.get('pid')), data.get('name'), data.get('sessionId')):
                sessions.append(data)
        except (OSError, ValueError):
            continue
    session = unique(sessions, 'Claude sessions')
    if session:
        if not session.get('messagingSocketPath') or not session.get('cwd') or not session.get('sessionId'):
            raise Refusal('Claude registry entry lacks socket, cwd or session ID')
        return ('claude', session['sessionId'], session)
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

def transcript(session):
    proc = subprocess.run(['bash', '-c', 'source "$1/transcript-confirm.sh"; hotline_transcript_candidates "$2" "$3"', 'send', str(SCRIPTS), session['cwd'], session['sessionId']], capture_output=True, text=True, check=True)
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
                    if claude and row.get('type') == 'system' and ('held peer message' in line.lower() or 'did not attest its permission mode' in line.lower()):
                        return 'held', str(path)
                    if nonce in line and (not claude or row.get('type') in ('user', 'queue-operation')):
                        return 'delivered', str(path)
            except OSError:
                pass
        if time.monotonic() >= deadline:
            return 'unconfirmed', 'no matching receiver transcript evidence'
        time.sleep(min(.2, max(0, deadline - time.monotonic())))

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
    nonce = str(uuid.uuid4())
    message = f'[{args.sender_name}]\n{args.message}\n\nReply: hotline send {sender} …\nMessage ID: {nonce}'
    evidence = ''
    if route == 't3':
        proc = subprocess.run(['t3', 'thread', 'send', target, '-'], input=message, capture_output=True, text=True)
        if proc.returncode: raise Refusal(f't3 send failed: {proc.stderr.strip()}')
        status, evidence = 'sent', proc.stdout.strip()
    elif route == 'claude':
        paths = transcript(detail); offsets = snapshot(paths)
        frame = {'type':'user', 'message':{'role':'user', 'content':message}, 'priority':'next', 'msg_id':nonce}
        if args.attest_mode: frame['fromMode'] = args.attest_mode
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5); sock.connect(detail['messagingSocketPath']); sock.sendall((json.dumps(frame)+'\n').encode())
        status, evidence = verify(paths, offsets, nonce, args.timeout, True)
    else:
        home, path = detail; paths = [path]; offsets = snapshot(paths)
        proc = subprocess.run(['codex','queue','--thread',target,'--message',message], env={**os.environ, 'CODEX_HOME':str(home)}, capture_output=True, text=True)
        if proc.returncode: raise Refusal(f'codex queue failed: {proc.stderr.strip()}')
        status, evidence = verify(paths, offsets, nonce, args.timeout)
    print(json.dumps({'status':status, 'route':route, 'target':target, 'evidence':evidence}))

if __name__ == '__main__':
    try: main()
    except (Refusal, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({'status':'error', 'route':None, 'target':None, 'evidence':str(exc)})); sys.exit(1)
