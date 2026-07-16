#!/usr/bin/env python3
"""Unit tests for adc_state.py. Pure file I/O, no network. Run:
python3 tests/test_adc_state.py"""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from adc_state import (  # noqa: E402
    get_entry,
    load_state,
    remove_entry,
    save_state,
    set_entry,
    source_key,
)


class TestAdcState(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.state_file = os.path.join(self.tmpdir, "sub", "rendered.json")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_source_key_is_absolute_and_stable(self):
        k1 = source_key("./foo.md")
        k2 = source_key(os.path.abspath("foo.md"))
        self.assertEqual(k1, k2)
        self.assertTrue(os.path.isabs(k1))

    def test_load_missing_file_returns_empty_dict(self):
        self.assertEqual(load_state(self.state_file), {})

    def test_load_corrupt_json_returns_empty_dict(self):
        os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
        with open(self.state_file, "w") as f:
            f.write("{not valid json")
        self.assertEqual(load_state(self.state_file), {})

    def test_round_trip_set_save_load_get(self):
        state = load_state(self.state_file)
        state = set_entry(state, "notes.md", "doc123", "Notes")
        save_state(state, self.state_file)

        reloaded = load_state(self.state_file)
        entry = get_entry(reloaded, "notes.md")
        self.assertEqual(entry, {"doc_id": "doc123", "title": "Notes"})

    def test_get_entry_unknown_source_returns_none(self):
        state = load_state(self.state_file)
        self.assertIsNone(get_entry(state, "never-seen.md"))

    def test_remove_entry(self):
        state = {}
        state = set_entry(state, "notes.md", "doc123", "Notes")
        state = remove_entry(state, "notes.md")
        self.assertIsNone(get_entry(state, "notes.md"))

    def test_creates_parent_directory(self):
        state = set_entry({}, "notes.md", "doc123", "Notes")
        save_state(state, self.state_file)
        self.assertTrue(os.path.exists(self.state_file))


if __name__ == "__main__":
    unittest.main()
