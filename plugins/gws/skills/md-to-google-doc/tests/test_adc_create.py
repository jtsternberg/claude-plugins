#!/usr/bin/env python3
"""Unit tests for adc_create.py's pure logic (folder-ID extraction). No
network access or Google client libraries required. Run:
python3 tests/test_adc_create.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from adc_create import extract_folder_id  # noqa: E402


class TestExtractFolderId(unittest.TestCase):
    def test_bare_id_passthrough(self):
        self.assertEqual(extract_folder_id("abc123"), "abc123")

    def test_full_url(self):
        self.assertEqual(
            extract_folder_id("https://drive.google.com/drive/u/0/folders/abc123"),
            "abc123",
        )

    def test_url_with_query_string(self):
        self.assertEqual(
            extract_folder_id("https://drive.google.com/drive/u/0/folders/abc123?resourcekey=0-x"),
            "abc123",
        )


if __name__ == "__main__":
    unittest.main()
