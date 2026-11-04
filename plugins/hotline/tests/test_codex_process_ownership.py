"""Descriptor/path replacement and framed lsof evidence, with no real processes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "ownership", Path(__file__).resolve().parents[1] / "scripts/codex-process-ownership.py"
)
ownership = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ownership)


class OwnershipTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.path = Path(self.scratch.name).resolve() / "rollout-fixture-thread.jsonl"
        self.header = json.dumps({"type": "session_meta", "payload": {"id": "thread"}}) + "\n"
        self.path.write_text(self.header)
        self.descriptor = self.path.stat()
        self.output = self.records()
        self.after_lsof = lambda: None
        self.births = 0
        self.change_birth = False
        self.lsof_error = False

    def records(self, name=None):
        return (b"p5151\0ccodex\0\nf7\0tREG\0D"
                + hex(self.descriptor.st_dev).encode() + b"\0i"
                + str(self.descriptor.st_ino).encode() + b"\0n"
                + str(name or self.path).encode() + b"\0\n")

    def run_command(self, args, **kwargs):
        if args[0] == "ps":
            self.assertEqual(args, ["ps", "-p", "5151", "-o", "lstart="])
            self.births += 1
            second = 1 if self.change_birth and self.births > 1 else 0
            data = f"Wed Nov  4 12:00:0{second} 2026\n".encode()
        else:
            self.assertEqual(args, ["lsof", "-nP", "-a", "-p", "5151", "-F0pcfDint"])
            if self.lsof_error:
                raise subprocess.CalledProcessError(1, args)
            self.after_lsof()
            data = self.output
        return subprocess.CompletedProcess(args, 0, stdout=data, stderr=b"")

    def verify(self):
        with patch.object(ownership.subprocess, "run", side_effect=self.run_command):
            ownership.verify("5151", str(self.path), "thread")

    def replace(self):
        self.path.unlink()
        self.path.write_text(self.header)

    def test_matching_current_descriptor(self):
        self.verify()

    def test_captured_darwin_npolicy_descriptor_is_not_a_rollout(self):
        # Exact record54 from pipeline-v2-smoke/followup-lsof.bin, including
        # its present-but-empty NAME field. All rollout/process evidence stays
        # independently required by the existing positive/negative controls.
        self.output += b"f37\0tNPOLICY\0n\0\n"
        self.verify()

    def test_empty_regular_or_untyped_file_name_still_refuses(self):
        good = self.output
        for record in (
            b"f37\0tREG\0n\0\n", b"f37\0n\0\n", b"f37\0tNPOLICY\0\n",
            b"f37\0tUNKNOWN\0n\0\n", b"fcwd\0tNPOLICY\0n\0\n",
            b"f\0tNPOLICY\0n\0\n", b"f37\0t\0n\0\n",
            b"f37\0tNPOLICY\0n\0n\0\n",
            b"f37\0tNPOLICY\0n\0D0x1000010\0\n",
            b"f37\0tNPOLICY\0n\0i123\0\n",
            b"f37\0tNPOLICY\0n", b"f37\0tNPOLICY\0n\0",
            b"f37\0tNPOLICY\0n/tmp/rollout-other.jsonl\0\n",
        ):
            with self.subTest(record=record):
                self.output = good + record
                with self.assertRaises(ValueError):
                    self.verify()

    def test_npolicy_alone_does_not_prove_rollout_ownership(self):
        self.output = b"p5151\0ccodex\0\nf37\0tNPOLICY\0n\0\n"
        with self.assertRaises(ValueError):
            self.verify()

    def test_npolicy_does_not_override_regular_file_identity(self):
        self.output = self.output.replace(
            b"i" + str(self.descriptor.st_ino).encode(), b"i0"
        ) + b"f37\0tNPOLICY\0n\0\n"
        with self.assertRaises(ValueError):
            self.verify()

    def test_ordinary_cwd_and_file_with_rollout_named_ancestor(self):
        parent = self.path.parent / "rollout-tools"
        parent.mkdir()
        config = parent / "config.toml"
        config.write_text("# fixture\n")
        good = self.output
        for path, fd, kind in ((parent, "cwd", "DIR"), (config, "8", "REG")):
            with self.subTest(path=path):
                st = path.stat()
                self.output = good + (f"f{fd}\0t{kind}\0D{hex(st.st_dev)}\0i{st.st_ino}\0n{path}\0\n").encode()
                self.verify()

    def test_same_path_recreated_with_different_inode(self):
        with self.path.open() as held:
            self.replace()
            self.assertNotEqual(self.path.stat().st_ino, self.descriptor.st_ino)
            with self.assertRaises(ValueError):
                self.verify()
            self.assertFalse(held.closed)

    def test_replacement_during_observation(self):
        with self.path.open():
            self.after_lsof = self.replace
            with self.assertRaises(ValueError):
                self.verify()

    def test_incomplete_or_deleted_second_rollout(self):
        good = self.output
        for extra in (b"f8\0tREG\0n/tmp/rollout-incomplete", b"f8\0tREG\0n/tmp/rollout-second.jsonl (deleted)\0\n"):
            with self.subTest(extra=extra):
                self.output = good + extra
                with self.assertRaises(ValueError):
                    self.verify()

    def test_missing_device_or_inode(self):
        good = self.output
        for field in (b"D", b"i"):
            with self.subTest(field=field):
                self.output = b"\0".join(token for token in good.split(b"\0") if not token.startswith(field))
                with self.assertRaises((ValueError, KeyError)):
                    self.verify()

    def test_wrong_process_record(self):
        self.output = self.output.replace(b"p5151", b"p6161")
        with self.assertRaises(ValueError):
            self.verify()

    def test_process_birth_changes(self):
        self.change_birth = True
        with self.assertRaises(ValueError):
            self.verify()

    def test_command_failure(self):
        self.lsof_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()


if __name__ == "__main__":
    unittest.main()
