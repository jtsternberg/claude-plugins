#!/usr/bin/env python3
"""Unit tests for adc_export.py's pure logic (doc-ID extraction). No network
access or Google client libraries required. Run: python3 tests/test_adc_export.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import adc_export  # noqa: E402
from adc_export import export_markdown, extract_doc_id  # noqa: E402


class FakeRequest:
    def __init__(self, result):
        self._result = result

    def execute(self):
        return self._result


class FakeFiles:
    def __init__(self, drive):
        self.drive = drive

    def export(self, **kw):
        self.drive.export_kwargs.append(kw)
        return FakeRequest(b"# exported\n")


class FakeDrive:
    def __init__(self):
        self.export_kwargs = []

    def files(self):
        return FakeFiles(self)


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


class TestExportRejectsSupportsAllDrives(unittest.TestCase):
    """The sibling md-to-google-doc skill needs supportsAllDrives=True on every
    Drive call or shared-drive writes 404. This one must NOT have it: Drive v3
    files.export accepts only fileId and mimeType, and googleapiclient validates
    kwargs against the discovery document, so passing it raises TypeError at
    runtime. A well-meaning "add the flag everywhere" sweep would break exports —
    hence a test rather than a comment. See claude-plugins-zwr7."""

    def setUp(self):
        self.real_clients = adc_export._clients
        self.drive = FakeDrive()
        adc_export._clients = lambda: self.drive

    def tearDown(self):
        adc_export._clients = self.real_clients

    def test_export_passes_only_fileid_and_mimetype(self):
        export_markdown("abc123")
        self.assertEqual(
            self.drive.export_kwargs,
            [{"fileId": "abc123", "mimeType": "text/markdown"}],
        )

    def test_export_does_not_pass_supports_all_drives(self):
        export_markdown("abc123")
        self.assertNotIn("supportsAllDrives", self.drive.export_kwargs[0])


if __name__ == "__main__":
    unittest.main()
