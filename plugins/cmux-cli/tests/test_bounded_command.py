"""Deadline subprocess handling without real sleeps or external processes."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[1] / 'skills/using-cmux-cli/scripts/bounded-command.py'
spec = importlib.util.spec_from_file_location('bounded_command', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BoundedCommandTests(unittest.TestCase):
    def test_success_and_failed_command(self):
        for status in (0, 1):
            with self.subTest(status=status), patch.object(module.subprocess, 'Popen') as popen:
                popen.return_value.wait.return_value = status
                self.assertEqual(module.run(3, ['cmux', 'send']), status)
                popen.return_value.wait.assert_called_once_with(timeout=3)
                popen.return_value.kill.assert_not_called()

    def test_timeout_kills_and_reaps_only_owned_child(self):
        for verb in ('send', 'read-screen', 'close-surface'):
            with self.subTest(verb=verb), patch.object(module.subprocess, 'Popen') as popen:
                child = popen.return_value
                child.wait.side_effect = [subprocess.TimeoutExpired(verb, 2), -9]
                self.assertEqual(module.run(2, ['cmux', verb]), 124)
                popen.assert_called_once_with(['cmux', verb])
                child.kill.assert_called_once_with()
                self.assertEqual(child.wait.call_count, 2)
                child.wait.assert_any_call()

    def test_absolute_deadline_accounts_for_spawn_time(self):
        with patch.object(module, 'clock', side_effect=[10.2, 10.7]), patch.object(module.subprocess, 'Popen') as popen:
            popen.return_value.wait.return_value = 0
            self.assertEqual(module.run(0, ['cmux', 'read-screen'], deadline=12), 0)
            self.assertAlmostEqual(popen.return_value.wait.call_args.kwargs['timeout'], 1.3)

    def test_expired_budget_never_starts_child(self):
        with patch.object(module.subprocess, 'Popen') as popen:
            self.assertEqual(module.run(0, ['cmux', 'send']), 124)
            popen.assert_not_called()

    def test_signal_during_spawn_reaps_returned_child(self):
        child = Mock()
        def spawn(_command):
            os.kill(os.getpid(), signal.SIGTERM)
            return child
        with patch.object(module.subprocess, 'Popen', side_effect=spawn):
            self.assertEqual(module.run(3, ['cmux']), 128 + signal.SIGTERM)
        child.kill.assert_called_once_with()
        child.wait.assert_called_once_with()

    def test_cancel_already_exited_child_does_not_mask_result(self):
        child = Mock()
        child.kill.side_effect = ProcessLookupError()
        def spawn(_command):
            os.kill(os.getpid(), signal.SIGINT)
            return child
        with patch.object(module.subprocess, 'Popen', side_effect=spawn):
            self.assertEqual(module.run(3, ['cmux']), 128 + signal.SIGINT)
        child.wait.assert_called_once_with()

    def test_wrapper_signals_reap_child_and_close_pipe(self):
        code = 'import os; print(os.getpid(), flush=True); os.read(0, 1)'
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                wrapper = subprocess.Popen([sys.executable, str(path), '20', sys.executable, '-c', code],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                try:
                    pid = int(wrapper.stdout.readline())
                    os.kill(wrapper.pid, sig)
                    stdout, _ = wrapper.communicate(timeout=5)
                    self.assertEqual(stdout, '')
                    self.assertEqual(wrapper.returncode, 128 + sig)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                finally:
                    if wrapper.poll() is None:
                        wrapper.kill()
                        wrapper.communicate()

    def test_foreground_group_interrupt_preserves_bystander(self):
        # The driver owns a fresh process group and reaps its bystander itself.
        driver = r'''
import os, signal, subprocess, sys
os.setpgrp()
signal.signal(signal.SIGINT, signal.SIG_IGN)
bystander = subprocess.Popen([sys.executable, '-c', 'import os; os.read(0, 1)'], stdin=subprocess.PIPE)
code = 'import os,signal; signal.signal(signal.SIGINT, signal.SIG_DFL); print(os.getpid(), flush=True); os.read(0, 1)'
wrapper = subprocess.Popen([sys.executable, sys.argv[1], '20', sys.executable, '-c', code], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    pid = int(wrapper.stdout.readline())
    os.killpg(os.getpgrp(), signal.SIGINT)
    output, _ = wrapper.communicate(timeout=5)
    try: os.kill(pid, 0); alive = True
    except ProcessLookupError: alive = False
    print(wrapper.returncode, int(alive), int(bystander.poll() is None), repr(output))
finally:
    if wrapper.poll() is None: wrapper.kill(); wrapper.communicate()
    bystander.kill(); bystander.wait()
'''
        result = subprocess.run([sys.executable, '-c', driver, str(path)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "130 0 1 ''")


if __name__ == '__main__':
    unittest.main()
