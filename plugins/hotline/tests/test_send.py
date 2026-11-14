import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import socket
import sqlite3
import tempfile
import threading
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
        self.db = self.home / '.t3/userdata/statev2.sqlite'
        self.db.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('create table orchestration_v2_projection_provider_threads (thread_id text, payload_json text)')

    def row(self, thread, native):
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('insert into orchestration_v2_projection_provider_threads values (?, ?)', (thread, json.dumps({'nativeThreadRef': {'nativeId': native}})))

    def registry(self, pid, name, session, sock):
        p = self.home / '.claude/sessions'
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

if __name__ == '__main__':
    unittest.main()
