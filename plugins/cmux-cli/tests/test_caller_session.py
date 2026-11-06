"""Real opener + stub cmux/ps, using selected fields captured on cmux 0.65.

The recorded workspace differs from the live one, focus belongs to a bystander,
and active flags are false. No process, model, network or UI is contacted.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

OPENER = Path(__file__).resolve().parents[1] / 'skills/using-cmux-cli/scripts/open-side-surface.sh'
SID = '11111111-1111-4111-8111-111111111111'
SURFACE = '22222222-2222-4222-8222-222222222222'
WS = '33333333-3333-4333-8333-333333333333'
WIN = '44444444-4444-4444-8444-444444444444'
PANE = '55555555-5555-4555-8555-555555555555'
NEW_PANE = '66666666-6666-4666-8666-666666666666'
NEW_SURFACE = '77777777-7777-4777-8777-777777777777'


class CallerSession(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('CMUX_', 'CODEX_', 'CLAUDE_CODE_', 'HOTLINE_'))}
        self.env.update(PATH=str(self.root) + os.pathsep + self.env['PATH'], FIXTURE=str(self.root), CODEX_THREAD_ID=SID)
        self.total_matches = None
        self.records = [{'agent': 'codex', 'session_id': SID, 'pid': 7777,
                         'surface_id': SURFACE, 'workspace_id': 'old-workspace',
                         'active_for_surface': False, 'active_for_workspace': False}]
        self.surface = dict(id=SURFACE, ref='surface:9', tty='ttys002')
        self.tree = dict(windows=[dict(id=WIN, ref='window:8', workspaces=[dict(
            id=WS, ref='workspace:7', title='current', panes=[dict(
                id=PANE, ref='pane:6', index=0, surfaces=[self.surface])])])])
        # Selected read-only capture fields; no stored arguments/transcripts needed.
        self.write('identify', {'caller': None, 'focused': dict(pane_ref='pane:99', workspace_ref='workspace:99', window_ref='window:99')})
        self.write('created', dict(surface_id=NEW_SURFACE, pane_id=NEW_PANE, workspace_id=WS,
                                   surface_ref='surface:10', pane_ref='pane:10', workspace_ref='workspace:7'))
        self.stub('sleep', '#!/bin/sh\nexit 0\n')
        self.stub('ps', '''#!/bin/sh
case "$*" in
  '-p 7777 -o ppid=,tty=,comm=')
    test ! -f "$FIXTURE/dead" || exit 1
    if test -f "$FIXTURE/reused"; then echo '1 ttys002 /bin/zsh'
    elif test -f "$FIXTURE/other_tty"; then echo '1 ttys003 /bin/codex'
    else echo "1 ttys002 /bin/${FAKE_AGENT:-codex}"; fi;;
  *) if test -f "$FIXTURE/not_ancestor"; then echo '1 ?? /bin/bash'; else echo '7777 ?? /bin/bash'; fi;;
esac
''')
        self.stub('cmux', '''#!/bin/sh
printf '%s\\n' "$*" >> "$FIXTURE/calls"
if test "$1" = --json; then shift 3; fi
case "$1" in
 identify) cat "$FIXTURE/identify";;
 sessions) test "$*" = "sessions --agent ${FAKE_AGENT:-codex} --session ''' + SID + ''' --json" || exit 9; cat "$FIXTURE/sessions";;
 tree) cat "$FIXTURE/tree";;
 new-pane|new-surface) cat "$FIXTURE/created";;
 rename-tab) :;;
 *) exit 9;;
esac
''')

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def stub(self, name, content):
        p = self.root / name
        p.write_text(content)
        p.chmod(0o755)

    def run_opener(self, *args):
        self.write('sessions', dict(sessions=self.records, total_matches=len(self.records) if self.total_matches is None else self.total_matches))
        self.write('tree', self.tree)
        return subprocess.run(['bash', str(OPENER), '--json', '--title', 'test', *args], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def accept(self, *args):
        result = self.run_opener(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['surface_id'], NEW_SURFACE)
        calls = (self.root / 'calls').read_text()
        self.assertIn('--workspace ' + WS, calls)
        self.assertEqual(json.loads(result.stdout)['workspace_ref'], 'workspace:7')
        self.assertNotIn('--workspace workspace:99', calls)

    def refuse(self):
        result = self.run_opener()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertIn('could not resolve caller.pane_ref / workspace_ref from identify', result.stderr)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('new-pane', calls)
        self.assertNotIn('new-surface', calls)

    def test_missing_environment_false_active_moved_surface(self):
        self.accept()

    def test_recovered_current_pane_chooses_its_adjacent_pane(self):
        panes = self.tree['windows'][0]['workspaces'][0]['panes']
        # Caller is in the middle; focus and a bystander sit on its left.
        panes[0]['index'] = 1
        panes.insert(0, dict(id='88888888-8888-4888-8888-888888888888',
                             ref='pane:99', index=0, surfaces=[]))
        panes.append(dict(id=NEW_PANE, ref='pane:10', index=2, surfaces=[]))
        self.accept()
        calls = (self.root / 'calls').read_text()
        self.assertIn('new-surface --pane ' + NEW_PANE, calls)
        self.assertIn('--window ' + WIN, calls)

    def test_wrong_account_record_with_unrelated_live_pid(self):
        self.records[0]['session_home'] = '/other-account/.codex'
        self.records[0]['pid'] = 8888
        self.refuse()

    def test_scoped_hotline_identity(self):
        self.env.update(CMUX_CALLER_AGENT='codex', CMUX_CALLER_SESSION_ID=SID)
        self.accept()

    def test_native_claude(self):
        self.env.pop('CODEX_THREAD_ID')
        self.env.update(CLAUDE_CODE_SESSION_ID=SID, FAKE_AGENT='claude')
        self.records[0]['agent'] = 'claude'
        self.accept()

    def test_valid_existing_identify_is_unchanged(self):
        self.write('identify', dict(caller=dict(pane_ref='pane:6', workspace_ref='workspace:7', window_ref='window:8')))
        self.records = []
        self.accept()
        self.assertNotIn('sessions ', (self.root / 'calls').read_text())

    def test_explicit_focused_is_unchanged(self):
        self.write('identify', dict(focused=dict(pane_ref='pane:6', workspace_ref='workspace:7', window_ref='window:8')))
        self.records = []
        self.accept('--focused')
        self.assertNotIn('sessions ', (self.root / 'calls').read_text())

    def test_valid_surface_environment_is_unchanged(self):
        self.env['CMUX_SURFACE_ID'] = SURFACE
        self.records = []
        self.accept()
        self.assertNotIn('sessions ', (self.root / 'calls').read_text())

    def test_stale_environment_recovers_by_session(self):
        self.env['CMUX_SURFACE_ID'] = NEW_SURFACE
        self.accept()

    def test_duplicate_records_across_accounts(self):
        self.records *= 2
        self.refuse()

    def test_truncated_ambiguous_session_query(self):
        self.total_matches = 2
        self.refuse()

    def test_null_tree_tty(self):
        self.surface['tty'] = None
        self.refuse()

    def test_wrong_session(self):
        self.records[0]['session_id'] = NEW_SURFACE
        self.refuse()

    def test_wrong_agent(self):
        self.records[0]['agent'] = 'claude'
        self.refuse()

    def test_override_cannot_borrow_another_native_session(self):
        self.env.update(CMUX_CALLER_SESSION_ID=NEW_SURFACE, CMUX_CALLER_AGENT='codex')
        self.refuse()

    def test_dead_pid(self):
        (self.root / 'dead').touch()
        self.refuse()

    def test_reused_pid_different_executable(self):
        (self.root / 'reused').touch()
        self.refuse()

    def test_live_codex_pid_outside_invocation_ancestry(self):
        (self.root / 'not_ancestor').touch()
        self.refuse()

    def test_process_tty_mismatch(self):
        (self.root / 'other_tty').touch()
        self.refuse()

    def test_tree_tty_mismatch(self):
        self.surface['tty'] = 'ttys999'
        self.refuse()

    def test_missing_tree_surface(self):
        self.surface['id'] = NEW_SURFACE
        self.refuse()

    def test_ambiguous_tree_surface(self):
        self.tree['windows'] *= 2
        self.refuse()

    def test_string_pid_is_untrusted(self):
        self.records[0]['pid'] = '7777'
        self.refuse()

    def test_boolean_pid_is_untrusted(self):
        self.records[0]['pid'] = True
        self.refuse()

    def test_malformed_surface_id(self):
        self.records[0]['surface_id'] = '--focused'
        self.refuse()

    def test_missing_native_session_never_borrows_focus(self):
        self.env.pop('CODEX_THREAD_ID')
        self.refuse()

    def test_missing_session_record_never_borrows_focus(self):
        self.records = []
        self.refuse()


if __name__ == '__main__':
    unittest.main()
