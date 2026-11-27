import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import socket
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'skills/send/scripts/send.py'
spec = importlib.util.spec_from_file_location('hotline_send', SCRIPT)
send = importlib.util.module_from_spec(spec)
spec.loader.exec_module(send)

class SendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.home_patch = patch.object(send, 'HOME', self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.env_patch = patch.dict(os.environ)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        os.environ.pop('CLAUDE_CONFIG_DIR', None)
        os.environ.pop('HOTLINE_CLAUDE_CONFIG_DIRS', None)
        os.environ.pop('AGENT_CLAUDE_CONFIG_DIRS', None)
        self.db = self.home / '.t3/userdata/statev2.sqlite'
        self.db.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('create table orchestration_v2_projection_provider_threads (thread_id text, payload_json text)')

    def row(self, thread, native):
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('insert into orchestration_v2_projection_provider_threads values (?, ?)', (thread, json.dumps({'nativeThreadRef': {'nativeId': native}})))

    def registry(self, pid, name, session, sock, config='.claude'):
        p = self.home / config / 'sessions'
        p.mkdir(parents=True, exist_ok=True)
        (p / f'{pid}.json').write_text(json.dumps({'pid': pid, 'name': name, 'sessionId': session, 'cwd': str(self.home), 'messagingSocketPath': str(sock)}))

    def test_t3_precedes_claude_and_accepts_prefix(self):
        self.row('abc', 'native')
        self.registry(1, 'worker', 'native', '/tmp/not-used')
        self.assertEqual(send.resolve('native')[:2], ('t3', 'abc'))
        self.assertEqual(send.resolve('thread_abc')[:2], ('t3', 'abc'))

    def test_t3_cli_thread_id_forms(self):
        tid = 'mcp:61800683-3799-4b14-a14d-d7ca85726f8c'
        native = '01a1d5a3-fae5-7311-88f2-441d3ae90f09'
        self.row('thread_' + tid, native)
        for ref in (tid, 'thread_' + tid, native):
            with self.subTest(ref=ref):
                self.assertEqual(send.resolve(ref)[:2], ('t3', tid))
        bare = '11111111-2222-3333-4444-555555555555'
        self.row('thread_' + bare, 'other-native')
        for ref in (bare, 'thread_' + bare):
            self.assertEqual(send.resolve(ref)[:2], ('t3', bare))

    def test_ambiguous_and_missing(self):
        self.registry(1, 'worker', 'one', '/tmp/one')
        self.registry(2, 'worker', 'two', '/tmp/two')
        with self.assertRaisesRegex(send.Refusal, 'ambiguous'):
            send.resolve('worker')
        with self.assertRaisesRegex(send.Refusal, 'candidates'):
            send.resolve('missing')
        self.assertEqual(send.resolve('1')[:2], ('claude', 'one'))

    def test_extra_config_dirs_var(self):
        (self.home / '.claude/sessions').mkdir(parents=True)
        self.registry(42, 'alt-worker', 'alt-sid', '/tmp/alt', config='.claude-alt')
        os.environ.pop('HOTLINE_CLAUDE_CONFIG_DIRS', None)
        with self.assertRaisesRegex(send.Refusal, 'no target matches'):
            send.resolve('alt-sid')
        os.environ['HOTLINE_CLAUDE_CONFIG_DIRS'] = f"{self.home / 'missing'}:{self.home / '.claude-alt'}"
        route, target, (session, config) = send.resolve('alt-sid')
        self.assertEqual((route, target, session['pid']), ('claude', 'alt-sid', 42))
        self.assertEqual(config, self.home / '.claude-alt')
        self.registry(7, 'main-worker', 'alt-sid', '/tmp/main')
        with self.assertRaisesRegex(send.Refusal, 'ambiguous'):
            send.resolve('alt-sid')

    def test_claude_config_dir_replaces_default_and_dedupes(self):
        custom = self.home / 'elsewhere'
        self.registry(9, 'w', 'env-sid', '/tmp/env', config='elsewhere')
        self.registry(3, 'w', 'main-sid', '/tmp/m')
        os.environ['CLAUDE_CONFIG_DIR'] = str(custom)
        self.assertEqual(send.resolve('env-sid')[2][1], custom)
        with self.assertRaisesRegex(send.Refusal, 'no target matches'):
            send.resolve('main-sid')
        # The same registry named twice must not read as a duplicate.
        (self.home / 'link').symlink_to(custom)
        os.environ['HOTLINE_CLAUDE_CONFIG_DIRS'] = f"{custom}:{self.home / 'link'}"
        self.assertEqual(send.resolve('env-sid')[1], 'env-sid')

    def test_transcript_reads_matched_config_dir_projects(self):
        cwd = self.home / 'proj'; cwd.mkdir()
        paths = send.transcript({'cwd': str(cwd), 'sessionId': 'sid'}, self.home / '.claude-alt')
        self.assertTrue(paths)
        for p in paths:
            self.assertTrue(str(p).startswith(str(self.home / '.claude-alt/projects/')), p)

    def test_schema_failure(self):
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('drop table orchestration_v2_projection_provider_threads')
        with self.assertRaisesRegex(send.Refusal, 'T3 ownership lookup unavailable'):
            send.resolve('anything')

    def test_socket_frame_and_verification(self):
        sockpath = self.home / 'socket'
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(sockpath)); server.listen()
        self.addCleanup(server.close)
        self.registry(1, 'worker', 'session', sockpath)
        transcript = self.home / 'transcript'
        received = []
        def receiver():
            conn, _ = server.accept()
            with conn:
                frame = json.loads(conn.makefile().readline())
                received.append(frame)
                transcript.write_text(json.dumps({'type':'user', 'message':frame['message']}) + '\n')
        thread = threading.Thread(target=receiver); thread.start()
        with patch.object(send, 'transcript', return_value=[transcript]), patch('sys.argv', ['send', 'worker', 'hello', '--sender-id', 'sender', '--attest-mode', 'bypass', '--timeout', '1']), patch('builtins.print') as output:
            send.main()
        thread.join(2)
        self.assertEqual(received[0]['type'], 'user')
        self.assertEqual(received[0]['priority'], 'next')
        self.assertEqual(received[0]['fromMode'], 'bypass')
        self.assertEqual(received[0]['message']['role'], 'user')
        self.assertIn(received[0]['msg_id'], received[0]['message']['content'][:60])
        self.assertRegex(received[0]['message']['content'], r'^m-[0-9a-f]+ \[agent\]')
        self.assertIn('Reply: hotline send sender', received[0]['message']['content'])
        self.assertEqual(json.loads(output.call_args.args[0])['status'], 'delivered')

    def test_verification_states(self):
        p = self.home / 'log'
        p.write_text(json.dumps({'type':'system','content':'Held peer message — preview: «agent nonce hello»'}) + '\n')
        self.assertEqual(send.verify([p], {p:0}, 'nonce', 0, True)[0], 'held')
        self.assertEqual(send.verify([p], {p:p.stat().st_size}, 'nonce', 0, True)[0], 'unconfirmed')
        p.write_text(json.dumps({'type':'event','payload':'nonce'}) + '\n')
        self.assertEqual(send.verify([p], {p:0}, 'nonce', 0)[0], 'delivered')

    def test_unrelated_hold_and_delivery_are_not_ours(self):
        p = self.home / 'log'
        p.write_text(json.dumps({'type':'system', 'content':'Held peer message — preview: «agent m-other hello»'}) + '\n' + json.dumps({'type':'user', 'message':'another message'}) + '\n')
        self.assertEqual(send.verify([p], {p:0}, 'm-ours', 0, True)[0], 'unconfirmed')

    def test_bracket_stripped_hold_preview_matches_our_id(self):
        p = self.home / 'log'
        p.write_text(json.dumps({'type':'system', 'subtype':'informational', 'content':'Held peer message — from an unidentified session; preview: «Sender m-ours hello» — not delivered to Claude'}) + '\n')
        self.assertEqual(send.verify([p], {p:0}, 'm-ours', 0, True)[0], 'held')

    def test_codex_cli_receives_account_and_confirms_rollout(self):
        home = self.home / '.codex-alt'; rollout = home / 'sessions/2026/01/01/rollout-now-12345678-1234-1234-1234-123456789abc.jsonl'
        rollout.parent.mkdir(parents=True); rollout.write_text('')
        bindir = self.home / 'bin'; bindir.mkdir()
        cli = bindir / 'codex'
        cli.write_text('#!/usr/bin/env python3\nimport json, os, sys\nopen(os.environ["HOME"] + "/account", "w").write(os.environ["CODEX_HOME"])\nwith open(os.environ["ROLLOUT"], "a") as f: f.write(json.dumps({"payload": sys.argv[5]}) + "\\n")\n')
        cli.chmod(0o755)
        # The real helper searches $HOME, while module HOME is patched for fixtures.
        with patch.dict(os.environ, {'PATH':str(bindir)+':'+os.environ['PATH'], 'HOME':str(self.home), 'ROLLOUT':str(rollout)}), patch('sys.argv', ['send','12345678-1234-1234-1234-123456789abc','hello','--sender-id','sender','--timeout','0']), patch('builtins.print') as output:
            send.main()
        self.assertEqual((self.home / 'account').read_text().strip(), str(home.resolve()))
        self.assertEqual(json.loads(output.call_args.args[0])['status'], 'delivered')

    def test_codex_queue_skips_cmux_shim_ahead_on_path(self):
        home = self.home / '.codex'; rollout = home / 'sessions/2026/01/01/rollout-now-12345678-1234-1234-1234-123456789abc.jsonl'
        rollout.parent.mkdir(parents=True); rollout.write_text('')
        shim = self.home / '.cmuxterm/cmux-cli-shims/0000/codex'; shim.parent.mkdir(parents=True)
        # Mirrors cmux's wrapper injecting a global flag that `codex queue` rejects.
        shim.write_text('#!/bin/sh\necho "error: \\`codex queue\\` does not support \\`--dangerously-bypass-hook-trust\\`" >&2\nexit 2\n')
        sniffed = self.home / 'wrapped'; sniffed.mkdir()
        (sniffed / 'codex').write_text('#!/bin/sh\nexec /Applications/cmux.app/Contents/Resources/bin/cmux-codex-wrapper "$@"\n')
        real = self.home / 'bin'; real.mkdir()
        (real / 'codex').write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["ROLLOUT"], "a") as f: f.write(json.dumps({"payload": sys.argv[5]}) + "\\n")\n')
        for cli in (shim, sniffed / 'codex', real / 'codex'): cli.chmod(0o755)
        path = ':'.join([str(shim.parent), str(sniffed), str(real), os.environ['PATH']])
        with patch.dict(os.environ, {'PATH':path, 'HOME':str(self.home), 'ROLLOUT':str(rollout)}), patch('sys.argv', ['send','12345678-1234-1234-1234-123456789abc','hello','--sender-id','sender','--timeout','0']), patch('builtins.print') as output:
            send.main()
        self.assertEqual(json.loads(output.call_args.args[0])['status'], 'delivered')

    def test_t3_cli_receives_envelope(self):
        self.row('abc', 'native')
        bindir = self.home / 'bin'; bindir.mkdir()
        cli = bindir / 't3'
        cli.write_text('#!/bin/sh\ncat > "$HOME/message"\necho Sent.\n')
        cli.chmod(0o755)
        with patch.dict(os.environ, {'PATH':str(bindir) + ':' + os.environ['PATH'], 'HOME':str(self.home)}), patch('sys.argv', ['send','thread_abc','hello','--sender-id','native']), patch('builtins.print') as output:
            send.main()
        self.assertEqual(json.loads(output.call_args.args[0])['status'], 'sent')
        self.assertIn('hotline send thread_abc', (self.home / 'message').read_text())

class SenderNotesTests(unittest.TestCase):
    """The sender's own "You should know" notes riding on its outgoing message."""
    SID = '11111111-2222-4333-8444-555555555555'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for p in (patch.object(send, 'HOME', self.home), patch.dict(os.environ)):
            p.start(); self.addCleanup(p.stop)
        for k in ('CLAUDE_CONFIG_DIR', 'HOTLINE_CLAUDE_CONFIG_DIRS', 'AGENT_CLAUDE_CONFIG_DIRS', 'HOTLINE_YSK_SEND_DIR'):
            os.environ.pop(k, None)
        # The reader reads $HOME's store; send hands it the module HOME.
        self.sessions = self.home / '.claude/sessions'; self.sessions.mkdir(parents=True)
        self.store_dir = self.home / '.claude/plugins/store'; self.store_dir.mkdir(parents=True)
        self.sock = self.home / 'sock'
        (self.sessions / '1.json').write_text(json.dumps({'pid': 1, 'name': 'worker', 'sessionId': 'callee', 'cwd': str(self.home), 'messagingSocketPath': str(self.sock)}))
        (self.sessions / '2.json').write_text(json.dumps({'pid': 2, 'name': 'boss', 'sessionId': self.SID, 'cwd': str(self.home), 'messagingSocketPath': '/tmp/unused'}))
        self.state = self.home / '.agents-hotline/you-should-know'
        self.cursor = self.state / f'{self.SID}.since'
        self.notes = self.state / f'{self.SID}.jsonl'

    def offer(self, shown_at, kind='offer'):
        view = {'kind': kind, 'line': 'the  migration\norder check will fail', 'explanation': 'LONG EXPLANATION', 'shownAt': shown_at}
        (self.store_dir / 'cc-plugin-you-should-know_builtin-a.json').write_text(json.dumps({'looksToSkip': 0, 'typedPastInARow': 0, 'sessions': [{'id': self.SID, 'tag': 'Heads up', 'view': view}]}))

    def set_cursor(self, ms):
        self.state.mkdir(parents=True, exist_ok=True); self.cursor.write_text(f'{ms}\n')

    def send(self, deliver=True, sender=None):
        """→ (content the receiver got, status, nonce). deliver=False leaves no transcript evidence."""
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.unlink(missing_ok=True); server.bind(str(self.sock)); server.listen()
        transcript = self.home / 'receiver.jsonl'; transcript.write_text('')
        got = []
        def receiver():
            conn, _ = server.accept()
            with conn:
                frame = json.loads(conn.makefile().readline())
                got.append(frame)
                if deliver:
                    transcript.write_text(json.dumps({'type': 'user', 'message': frame['message']}) + '\n')
        thread = threading.Thread(target=receiver); thread.start()
        try:
            argv = ['send', 'worker', 'hello', '--sender-id', sender or self.SID, '--timeout', '1' if deliver else '0']
            with patch.object(send, 'transcript', return_value=[transcript]), patch('sys.argv', argv), patch('builtins.print') as output:
                send.main()
        finally:
            thread.join(2); server.close()
        return got[0]['message']['content'], json.loads(output.call_args.args[0])['status'], got[0]['msg_id']

    def plain(self, nonce, sender=None):
        # The envelope exactly as send.py built it before sender notes existed.
        return f'{nonce} [agent]\nhello\n\nReply: hotline send {sender or self.SID} …\nMessage ID: {nonce}'

    def test_first_send_seeds_cursor_and_relays_nothing(self):
        self.offer(5000)
        before = int(time.time() * 1000)
        content, status, nonce = self.send()
        self.assertEqual(status, 'delivered')
        self.assertEqual(content, self.plain(nonce))
        self.assertGreaterEqual(int(self.cursor.read_text()), before)
        self.assertFalse(self.notes.exists())

    def test_no_new_note_is_byte_identical(self):
        self.offer(5000); self.set_cursor(5000)
        content, _, nonce = self.send()
        self.assertEqual(content, self.plain(nonce))
        self.assertEqual(self.cursor.read_text(), '5000\n')

    def test_new_note_carried_compactly_once(self):
        self.offer(5000); self.set_cursor(1000)
        content, status, nonce = self.send()
        self.assertEqual(status, 'delivered')
        self.assertEqual(content, f'{nonce} [agent]\nhello\n\n'
            f"Sender's You-should-know notes (full text: {self.notes}):\n"
            'Heads up: the migration order check will fail'
            f'\n\nReply: hotline send {self.SID} …\nMessage ID: {nonce}')
        self.assertNotIn('LONG EXPLANATION', content)
        kept = [json.loads(l) for l in self.notes.read_text().splitlines()]
        self.assertEqual([(n['explanation'], n['shownAt']) for n in kept], [('LONG EXPLANATION', 5000)])
        self.assertEqual(self.cursor.read_text(), '5000\n')
        content, _, nonce = self.send()
        self.assertEqual(content, self.plain(nonce))

    def test_undelivered_send_keeps_cursor_and_retry_recarries(self):
        self.offer(5000); self.set_cursor(1000)
        content, status, _ = self.send(deliver=False)
        self.assertEqual(status, 'unconfirmed')
        self.assertIn('Heads up: the migration order check will fail', content)
        self.assertEqual(self.cursor.read_text(), '1000\n')
        content, status, _ = self.send()
        self.assertEqual(status, 'delivered')
        self.assertIn('Heads up: the migration order check will fail', content)
        self.assertEqual(self.cursor.read_text(), '5000\n')
        self.assertEqual(len(self.notes.read_text().splitlines()), 1)

    def test_reader_failure_sends_unchanged(self):
        self.offer(5000); self.set_cursor(1000)
        for body in ('exit 1', 'echo not-json', 'echo \'{"notes":"x"}\'', 'sleep 3'):
            with self.subTest(body=body):
                bad = self.home / 'bad-reader.sh'; bad.write_text(body + '\n')
                with patch.object(send, 'YSK_READER', bad), patch.dict(os.environ, {'HOTLINE_YSK_SEND_TIMEOUT': '0.3'}):
                    content, status, nonce = self.send()
                self.assertEqual((content, status), (self.plain(nonce), 'delivered'))
                self.assertEqual(self.cursor.read_text(), '1000\n')

    def test_broken_store_appends_one_line(self):
        self.offer(5000, kind='brand-new-kind'); self.set_cursor(1000)
        content, _, nonce = self.send()
        head, tail = self.plain(nonce).split('\n\nReply:')
        self.assertTrue(content.startswith(head + '\n\nSender-side note relay: maybe the you-should-know relay is broken: unknown view kind'), content)
        self.assertTrue(content.endswith('\n\nReply:' + tail))
        self.assertEqual(content.count('\n'), self.plain(nonce).count('\n') + 2)
        self.assertEqual(self.cursor.read_text(), '1000\n')

    def test_sender_not_a_claude_session_is_untouched(self):
        self.offer(5000)
        content, _, nonce = self.send(sender='codex-thread-1')
        self.assertEqual(content, self.plain(nonce, 'codex-thread-1'))
        self.assertFalse(self.state.exists())
        self.assertIsNone(send.ysk_collect(None))
        self.assertIsNone(send.ysk_collect('../escape'))

if __name__ == '__main__':
    unittest.main()
