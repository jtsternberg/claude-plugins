import json, os, pathlib, stat, sys, tempfile, time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "scripts"))
import codex_timer  # noqa: E402

THREAD = "01a1c683-2797-7ea0-9bae-5e9da38af73d"


def add_rollout(home, thread=THREAD):
    day = home / "sessions" / "2026" / "11" / "10"
    day.mkdir(parents=True, exist_ok=True)
    (day / f"rollout-2026-11-10T12-30-46-{thread}.jsonl").write_text("{}\n")


def fake_codex(directory, body):
    path = directory / "codex"
    path.write_text("#!/bin/sh\n"
                    'if [ "$2" = "--help" ]; then echo "--thread <T> --message <M>"; exit 0; fi\n'
                    + body)
    path.chmod(0o755)
    return str(path)


class ResolveHomeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.user = pathlib.Path(self.tmp.name)
        self.default = self.user / ".codex"
        self.work = self.user / ".codex-work"
        self.default.mkdir()
        self.work.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_current_home_wins_when_it_owns_the_thread(self):
        add_rollout(self.default)
        add_rollout(self.work)
        home, source = codex_timer.resolve_codex_home(THREAD, {}, self.user)
        self.assertEqual((home, source), (self.default.resolve(), "current"))

    def test_explicit_codex_home_is_the_current_home(self):
        add_rollout(self.work)
        home, source = codex_timer.resolve_codex_home(THREAD, {"CODEX_HOME": str(self.work)}, self.user)
        self.assertEqual((home, source), (self.work.resolve(), "current"))

    def test_falls_back_to_the_single_other_home_that_owns_the_thread(self):
        # The observed failure: thread lives in ~/.codex-work, timer env resolved ~/.codex.
        add_rollout(self.work)
        home, source = codex_timer.resolve_codex_home(THREAD, {}, self.user)
        self.assertEqual((home, source), (self.work.resolve(), "alternative"))

    def test_refuses_when_several_other_homes_own_the_thread(self):
        other = self.user / ".codex-personal"
        add_rollout(self.work)
        add_rollout(other)
        with self.assertRaisesRegex(codex_timer.ArmError, "several Codex homes"):
            codex_timer.resolve_codex_home(THREAD, {}, self.user)

    def test_refuses_when_no_home_owns_the_thread(self):
        add_rollout(self.work, thread="02f38d8e-a5d2-4768-a004-d826c2bebbf4")
        with self.assertRaisesRegex(codex_timer.ArmError, "no rollout"):
            codex_timer.resolve_codex_home(THREAD, {}, self.user)

    def test_prepare_pins_the_home_into_the_job_config(self):
        add_rollout(self.work)
        payload = self.user / "payload.txt"
        payload.write_text("go $HOME `x` \\n")
        codex = fake_codex(self.user, "exit 0\n")
        when = "2099-01-01T00:00:00-05:00"
        config = codex_timer.prepare(when, payload, {"CODEX_THREAD_ID": THREAD}, self.user, codex=codex)
        self.assertEqual(config["codex_home"], str(self.work.resolve()))
        self.assertEqual(config["home_source"], "alternative")
        self.assertEqual(config["payload"], "go $HOME `x` \\n")


class ResolveCodexTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.shim_dir = self.root / "cmux-cli-shims" / "4790B522"
        self.real_dir = self.root / "bin"
        self.shim_dir.mkdir(parents=True)
        self.real_dir.mkdir()
        # Shape of the real shim: a bash script that execs cmux-codex-wrapper.
        fake_codex(self.shim_dir, "exec /Applications/cmux.app/Contents/Resources/bin/cmux-codex-wrapper\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_skips_the_cmux_shim_ahead_of_the_real_binary(self):
        real = fake_codex(self.real_dir, "exit 0\n")
        path = os.pathsep.join([str(self.shim_dir), str(self.real_dir)])
        self.assertEqual(codex_timer.resolve_codex({"PATH": path}), real)

    def test_skips_a_wrapper_script_outside_the_shim_directory(self):
        moved = self.root / "elsewhere"
        moved.mkdir()
        fake_codex(moved, "exec cmux-codex-wrapper \"$@\"\n")
        real = fake_codex(self.real_dir, "exit 0\n")
        path = os.pathsep.join([str(moved), str(self.real_dir)])
        self.assertEqual(codex_timer.resolve_codex({"PATH": path}), real)

    def test_refuses_when_only_the_wrapper_is_on_path(self):
        with self.assertRaisesRegex(codex_timer.ArmError, "cmux codex wrapper"):
            codex_timer.resolve_codex({"PATH": str(self.shim_dir)})


class FireTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        self.job = self.dir / "job"
        self.job.mkdir()
        self.home = self.dir / ".codex-work"

    def tearDown(self):
        self.tmp.cleanup()

    def run_fire(self, body):
        config = {"codex": fake_codex(self.dir, body), "thread": THREAD,
                  "codex_home": str(self.home), "target": time.time() - 1, "payload": "hello"}
        (self.job / "job.json").write_text(json.dumps(config))
        codex_timer.fire(self.job)
        return (self.job / "status").read_text().strip()

    def test_failure_status_carries_the_queue_error_and_stderr_is_kept_privately(self):
        status = self.run_fire(
            'echo "Error: failed to queue session message: no rollout found for thread id $3" >&2\n'
            "exit 1\n")
        self.assertEqual(status, "enqueue_failed rc=1: Error: failed to queue session message: "
                                 f"no rollout found for thread id {THREAD}")
        stderr_file = self.job / "queue.stderr"
        self.assertIn("no rollout found", stderr_file.read_text())
        self.assertEqual(stat.S_IMODE(stderr_file.stat().st_mode) & 0o077, 0)

    def test_diagnostics_are_bounded(self):
        status = self.run_fire("yes xxxxxxxxxxxxxxxxxxxxxxxx | head -c 100000 >&2\nexit 3\n")
        self.assertTrue(status.startswith("enqueue_failed rc=3: "))
        self.assertLessEqual(len(status), len("enqueue_failed rc=3: ") + codex_timer.STATUS_DETAIL_LIMIT)
        self.assertEqual(len((self.job / "queue.stderr").read_bytes()), codex_timer.DIAG_LIMIT)

    def test_queue_runs_with_the_pinned_codex_home(self):
        marker = self.dir / "seen-home"
        status = self.run_fire(f'printf %s "$CODEX_HOME" > "{marker}"\nexit 0\n')
        self.assertEqual(status, "enqueued")
        self.assertEqual(marker.read_text(), str(self.home))


class RecurringTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.job = pathlib.Path(self.tmp.name)
        self.clock = 0
        self.sent = []
        self.config = {"codex": "/fake/codex", "thread": THREAD, "codex_home": "/fake/home",
                       "target": 10, "every": 90, "expires": 500,
                       "payload": "[Caller label] do X literally $HOME `x` \\n"}

    def tearDown(self):
        self.tmp.cleanup()

    def run_timer(self, sleep, enqueue=None):
        (self.job / "job.json").write_text(json.dumps(self.config))

        def send(argv, **kwargs):
            self.sent.append((self.clock, argv))
            if enqueue:
                return enqueue(argv, **kwargs)
            return SimpleNamespace(returncode=0, stdout=b"ok", stderr=b"")

        with patch.object(codex_timer.time, "time", side_effect=lambda: self.clock), \
                patch.object(codex_timer.time, "sleep", side_effect=sleep), \
                patch.object(codex_timer.subprocess, "run", side_effect=send):
            codex_timer.repeat(self.job)

    def test_recurs_without_model_rearm_and_coalesces_until_acknowledged(self):
        def sleep(seconds):
            self.clock += seconds
            if self.clock == 190:
                (self.job / "pending").unlink()
            if self.clock >= 280:
                (self.job / "cancel").touch()

        self.run_timer(sleep)
        self.assertEqual([at for at, _ in self.sent], [10, 190])
        payload = self.sent[0][1][-1]
        self.assertTrue(payload.startswith(self.config["payload"]))
        self.assertIn(str(self.job), payload)
        self.assertIn("Do not re-arm", payload)
        self.assertEqual((self.job / "status").read_text().strip(), "cancelled")

    def test_sleep_skips_missed_intervals_and_keeps_original_phase(self):
        def sleep(seconds):
            self.clock = 245 if self.clock == 0 else self.clock + seconds
            if self.clock >= 280:
                (self.job / "cancel").touch()

        self.run_timer(sleep)
        self.assertEqual([at for at, _ in self.sent], [245])
        self.assertEqual(json.loads((self.job / "job.json").read_text())["target"], 280)

    def test_queue_failure_stops_instead_of_retrying(self):
        def sleep(seconds):
            self.clock += seconds

        self.run_timer(sleep, lambda *a, **k: SimpleNamespace(returncode=1, stdout=b"", stderr=b"offline"))
        self.assertEqual(len(self.sent), 1)
        self.assertTrue((self.job / "pending").exists())
        self.assertIn("enqueue_failed", (self.job / "status").read_text())

    def test_timeout_stops_with_unknown_outcome(self):
        def sleep(seconds):
            self.clock += seconds

        def timeout(*args, **kwargs):
            raise codex_timer.subprocess.TimeoutExpired("queue", 60)

        self.run_timer(sleep, timeout)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual((self.job / "status").read_text().strip(), "enqueue_timeout outcome_unknown")

    def test_expiry_stops_even_while_a_ping_is_pending(self):
        self.config["expires"] = 110

        def sleep(seconds):
            self.clock += seconds

        self.run_timer(sleep)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual((self.job / "status").read_text().strip(), "expired")

    def test_cancel_before_first_ping_never_enqueues(self):
        (self.job / "cancel").touch()
        self.run_timer(lambda seconds: self.fail("cancelled job slept"))
        self.assertEqual(self.sent, [])

    def test_subminute_and_invalid_intervals_are_rejected(self):
        for value in ("0", "-1", "59", "nan", "1.5"):
            with self.assertRaises(codex_timer.argparse.ArgumentTypeError):
                codex_timer.interval(value)
        self.assertEqual(codex_timer.interval("5400"), 5400)


if __name__ == "__main__":
    unittest.main()
