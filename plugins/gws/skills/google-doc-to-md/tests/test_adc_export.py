#!/usr/bin/env python3
"""Unit tests for adc_export.py's pure logic (doc-ID extraction). No network
access or Google client libraries required. Run: python3 tests/test_adc_export.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from adc_export import extract_doc_id  # noqa: E402


class TestExtractDocId(unittest.TestCase):
    def test_bare_id_passthrough(self):
        self.assertEqual(extract_doc_id("abc123"), "abc123")

    def test_full_url(self):
        self.assertEqual(
            extract_doc_id("https://docs.google.com/document/d/abc123/edit"),
            "abc123",
        )

    def test_url_with_query_string(self):
        self.assertEqual(
            extract_doc_id("https://docs.google.com/document/d/abc123/edit?usp=sharing"),
            "abc123",
        )

    def test_url_with_fragment(self):
        self.assertEqual(
            extract_doc_id("https://docs.google.com/document/d/abc123#heading=h.xyz"),
            "abc123",
        )


if __name__ == "__main__":
    unittest.main()
