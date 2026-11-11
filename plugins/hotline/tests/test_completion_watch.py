"""Completion wakes use stubbed Codex and real private per-test call dirs."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
WATCH = ROOT / "scripts/completion-watch.py"
THREAD = "11111111-2222-4333-8444-555555555555"


class CompletionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hl-wake-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base / "codex-home"
        sessions = self.home / "sessions"
        sessions.mkdir(parents=True)
        self.rollout = sessions / f"rollout-fixture-{THREAD}.jsonl"
        self.rollout.write_text(json.dumps({"type": "session_meta", "payload": {"id": THREAD}}) + "\n")
        self.call = self.base / "call"
        self.call.mkdir()
        (self.call / "call_id.txt").write_text("nonce123\n")
        (self.call / "transport.txt").write_text("headless\n")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        codex = self.bin / "codex"
        codex.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
base = Path(os.environ["PROBE_BASE"])
if sys.argv[1:] == ["queue", "--help"]:
    print("--thread --message" if (base/"no-capability").exists() else "--thread --message --resume")
elif sys.argv[1:] == ["app-server", "daemon", "version"]:
    print(json.dumps({"status": "stopped" if (base/"dead").exists() else "running",
        "socketPath": str(Path(os.environ["CODEX_HOME"])/"app-server-control/app-server-control.sock")}))
else:
    assert sys.argv[1] == "queue" and "--resume" in sys.argv
    assert "--remote" in sys.argv
    assert sys.argv[sys.argv.index("--remote")+1] == "unix://" + os.environ["CODEX_HOME"] + "/app-server-control/app-server-control.sock"
    with (base/"queue.log").open("a") as f: f.write(json.dumps({"argv":sys.argv[1:],"home":os.environ["CODEX_HOME"]})+"\\n")
    if (base/"fail").exists(): sys.exit(1)
    if (base/"warning").exists(): print("Warning: message was queued, but could not resume thread", file=sys.stderr)
    if not (base/"no-arrival").exists():
        with Path(os.environ["PROBE_ROLLOUT"]).open("a") as f:
            f.write(json.dumps({"type":"event_msg","payload":{"type":"user_message","message":sys.argv[sys.argv.index("--message")+1]}})+"\\n")
    print("Queued message submission-1 for thread " + sys.argv[sys.argv.index("--thread")+1] + ".")
''')
        codex.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        PROBE_BASE=str(self.base), PROBE_ROLLOUT=str(self.rollout), HOTLINE_POLL_SLEEP="0.01",
                        CODEX_THREAD_ID=THREAD)
        self.watch = WATCH

    def run_watch(self, *extra):
        return subprocess.run(["python3", str(self.watch), "arm", str(self.call),
            "--caller-thread", THREAD, "--caller-home", str(self.home),
            "--timeout", "600", "--arrival-timeout", "0.3", *extra],
            env=self.env, capture_output=True, text=True, timeout=8)

    def finish(self):
        (self.call / "response.json").write_text(json.dumps({"session_id":"callee", "response":"verified result"}))
        (self.call / "done").touch()

    def state(self):
        path = self.call / "completion" / "status.json"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists():
                state = json.loads(path.read_text())
                if state["state"] not in ("armed", "waiting", "enqueue_started", "enqueued"):
                    ready = self.call / "completion/ready.json"
                    if not ready.exists():
                        return state
                    pid = json.loads(ready.read_text())["pid"]
                    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
                    if str(self.call / "completion/runtime") not in command.stdout:
                        return state
            time.sleep(0.01)
        self.fail("watcher did not reach a bounded terminal state")

    def test_completion_after_arm_reaches_original_home_once(self):
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["state"], "armed")
        self.finish()
        self.assertEqual(self.state()["state"], "arrived")
        again = self.run_watch()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.state()["state"], "arrived")
        rows = [json.loads(x) for x in (self.base / "queue.log").read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["home"], str(self.home))
        self.assertIn(THREAD, rows[0]["argv"])
        self.assertEqual((self.call / "completion").stat().st_mode & 0o777, 0o700)

    def test_wrong_home_and_duplicate_rollouts_refuse_before_start(self):
        self.rollout.unlink()
        result = self.run_watch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one", result.stderr)
        self.rollout.write_text(json.dumps({"type":"session_meta","payload":{"id":THREAD}})+"\n")
        (self.home / "sessions" / f"rollout-other-{THREAD}.jsonl").write_text(self.rollout.read_text())
        result = self.run_watch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one", result.stderr)
        self.assertFalse((self.base / "queue.log").exists())

    def test_receiver_missing_refuses_arming(self):
        (self.base / "dead").touch()
        result = self.run_watch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("running", result.stderr)
        (self.base / "dead").unlink()
        self.finish()
        self.assertEqual(self.run_watch().returncode, 0)
        self.assertEqual(self.state()["state"], "arrived")

    def test_enqueue_ack_without_arrival_is_unconfirmed_and_never_retried(self):
        (self.base / "no-arrival").touch()
        self.finish()
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["state"], "arrival_unconfirmed")
        self.run_watch()
        self.assertEqual(self.state()["state"], "arrival_unconfirmed")
        self.assertEqual(len((self.base / "queue.log").read_text().splitlines()), 1)

    def test_failed_enqueue_is_durable_and_not_retried(self):
        (self.base / "fail").touch()
        self.finish()
        self.assertEqual(self.run_watch().returncode, 0)
        self.assertEqual(self.state()["state"], "enqueue_failed")
        self.run_watch()
        self.assertEqual(self.state()["state"], "enqueue_failed")
        self.assertEqual(len((self.base / "queue.log").read_text().splitlines()), 1)

    def test_cache_reconciliation_cannot_remove_running_waiter_helpers(self):
        install = self.base / "versioned-install"
        shutil.copytree(ROOT / "scripts", install / "scripts")
        shutil.copytree(ROOT / "skills/dial/scripts", install / "skills/dial/scripts")
        self.watch = install / "scripts/completion-watch.py"
        self.assertEqual(self.run_watch().returncode, 0)
        shutil.rmtree(install)
        self.finish()
        self.assertEqual(self.state()["state"], "arrived")

    def test_live_rearm_reuses_worker_without_starting_a_second_waiter(self):
        first = self.run_watch()
        second = self.run_watch()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(first.stdout)["pid"], json.loads(second.stdout)["pid"])
        self.assertTrue(json.loads(second.stdout)["watcher_live"])
        self.finish()
        self.assertEqual(self.state()["state"], "arrived")

    def test_receiver_dies_after_arm_no_queue_attempt(self):
        self.assertEqual(self.run_watch().returncode, 0)
        (self.base / "dead").touch()
        self.finish()
        self.assertEqual(self.state()["state"], "receiver_unavailable")
        self.assertFalse((self.base / "queue.log").exists())

    def test_resume_warning_with_success_exit_is_not_delivery(self):
        (self.base / "warning").touch()
        (self.base / "no-arrival").touch()
        self.finish()
        self.assertEqual(self.run_watch().returncode, 0)
        self.assertEqual(self.state()["state"], "arrival_unconfirmed")
        self.assertIn("Warning:", (self.call / "completion/queue.stderr").read_text())

    def test_arrival_ignores_assistant_tool_queue_and_historical_nonce(self):
        spec = importlib.util.spec_from_file_location("completion", WATCH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        marker = "[Hotline completion] call_id=nonce123"
        row = {"type":"event_msg", "payload":{"type":"user_message", "message":marker}}
        self.rollout.write_text(json.dumps(row) + "\n")
        offset = self.rollout.stat().st_size
        with self.rollout.open("a") as handle:
            for kind in ("agent_message", "queue", "function_call_output"):
                handle.write(json.dumps({"type":"event_msg", "payload":{"type":kind,"message":marker}})+"\n")
        self.assertFalse(module.arrival(self.rollout, offset, marker))
        with self.rollout.open("a") as handle:
            handle.write(json.dumps(row)+"\n")
        self.assertTrue(module.arrival(self.rollout, offset, marker))

    def test_rollout_header_mismatch_refuses_before_enqueue(self):
        self.rollout.write_text(json.dumps({"type":"session_meta", "payload":{"id":"wrong"}})+"\n")
        result = self.run_watch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("identity mismatch", result.stderr)
        self.assertFalse((self.base / "queue.log").exists())

    def test_existing_thread_must_match_calling_thread_when_exported(self):
        self.env["CODEX_THREAD_ID"] = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        self.finish()
        result = self.run_watch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("calling thread", result.stderr)
        self.assertFalse((self.base / "queue.log").exists())

    def test_missing_resume_capability_is_an_arm_failure(self):
        (self.base / "no-capability").touch()
        result = self.run_watch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capability unavailable", result.stderr)
        self.assertEqual(json.loads((self.call / "completion/status.json").read_text())["state"], "arm_failed")
        self.assertFalse((self.base / "queue.log").exists())

    def test_crash_after_enqueue_started_never_spends_nonce_twice(self):
        self.finish()
        self.assertEqual(self.run_watch().returncode, 0)
        self.assertEqual(self.state()["state"], "arrived")
        (self.call / "completion/status.json").write_text(json.dumps({"state":"enqueue_started"}))
        again = self.run_watch()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(json.loads(again.stdout)["state"], "enqueue_unknown")
        self.assertEqual(len((self.base / "queue.log").read_text().splitlines()), 1)

    def test_waiter_error_wakes_caller_with_failure_instead_of_success(self):
        (self.call / "response.json").write_text("invalid JSON")
        (self.call / "done").touch()
        self.assertEqual(self.run_watch().returncode, 0)
        state = self.state()
        self.assertEqual(state["state"], "arrived")
        self.assertNotEqual(state["waiter_exit"], 0)
        row = json.loads((self.base / "queue.log").read_text())
        self.assertIn(f"waiter_exit={state['waiter_exit']}", row["argv"][row["argv"].index("--message")+1])


if __name__ == "__main__":
    unittest.main()
