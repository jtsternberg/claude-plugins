#!/usr/bin/env python3
"""Unit tests for adc_create.py. No network access and no Google client
libraries required — adc_create imports googleapiclient lazily inside each
function, so a minimal stub in sys.modules covers the Drive-facing paths.
Keep it that way: CI installs no python packages. Run:
python3 tests/test_adc_create.py"""
import os
import sys
import types
import unittest


def _install_googleapiclient_stub():
    """Stand in a fake googleapiclient with only what adc_create touches.

    Installed unconditionally rather than only-if-absent: if the real library
    happens to be present locally, tests would otherwise exercise a different
    HttpError than CI does, and status_code behavior is the thing under test.
    """

    class HttpError(Exception):
        def __init__(self, status_code, reason=""):
            super().__init__(f"HTTP {status_code}: {reason}")
            self.status_code = status_code
            self.reason = reason

    errors_mod = types.ModuleType("googleapiclient.errors")
    errors_mod.HttpError = HttpError

    http_mod = types.ModuleType("googleapiclient.http")

    def _media(path, mimetype=None):
        return {"path": path, "mimetype": mimetype}

    http_mod.MediaFileUpload = _media

    pkg = types.ModuleType("googleapiclient")
    pkg.errors = errors_mod
    pkg.http = http_mod

    sys.modules["googleapiclient"] = pkg
    sys.modules["googleapiclient.errors"] = errors_mod
    sys.modules["googleapiclient.http"] = http_mod
    return HttpError


HttpError = _install_googleapiclient_stub()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from adc_create import (  # noqa: E402
    create_doc,
    doc_exists,
    extract_folder_id,
    update_doc,
)


class FakeRequest:
    def __init__(self, result=None, error=None):
        self._result = result
        self._error = error

    def execute(self):
        if self._error is not None:
            raise self._error
        return self._result


class FakeFiles:
    def __init__(self, drive):
        self.drive = drive

    def get(self, **kw):
        self.drive.calls.append(("get", kw))
        return FakeRequest(self.drive.get_result, self.drive.get_error)

    def create(self, **kw):
        self.drive.calls.append(("create", kw))
        return FakeRequest({"id": "created-doc-id"}, self.drive.create_error)

    def update(self, **kw):
        self.drive.calls.append(("update", kw))
        return FakeRequest({}, self.drive.update_error)


class FakeDrive:
    def __init__(self):
        self.calls = []
        self.get_result = {"id": "doc-abc"}
        self.get_error = None
        self.create_error = None
        self.update_error = None

    def files(self):
        return FakeFiles(self)


class FakeDocs:
    """Stands in for the Docs v1 client used by _set_pageless."""

    def __init__(self):
        self.batch_updates = []

    def documents(self):
        return self

    def batchUpdate(self, **kw):  # noqa: N802 - mirrors the Google client API
        self.batch_updates.append(kw)
        return FakeRequest({})

    def kwargs_for(self, key):
        return [b.get(key) for b in self.batch_updates]


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


class TestSupportsAllDrives(unittest.TestCase):
    """Shared-drive docs read fine but 404 on write without supportsAllDrives,
    and a missing flag on files.get made doc_exists() report False and silently
    create a duplicate. Three keyword arguments with nothing pinning them is how
    that regresses, so pin them. See claude-plugins-zwr7."""

    def test_get_passes_supports_all_drives(self):
        drive = FakeDrive()
        doc_exists(drive, "doc-abc")
        self.assertEqual(drive.calls[0][1].get("supportsAllDrives"), True)

    def test_create_passes_supports_all_drives(self):
        drive, docs = FakeDrive(), FakeDocs()
        create_doc(drive, docs, "/tmp/x.md", "Title", None)
        create_kw = dict(drive.calls)["create"]
        self.assertEqual(create_kw.get("supportsAllDrives"), True)

    def test_update_passes_supports_all_drives(self):
        drive = FakeDrive()
        update_doc(drive, "doc-abc", "/tmp/x.md", "Title")
        update_kw = dict(drive.calls)["update"]
        self.assertEqual(update_kw.get("supportsAllDrives"), True)

    def test_create_sets_pageless_and_honors_folder(self):
        drive, docs = FakeDrive(), FakeDocs()
        doc_id = create_doc(drive, docs, "/tmp/x.md", "Title", "folder-1")
        self.assertEqual(doc_id, "created-doc-id")
        self.assertEqual(dict(drive.calls)["create"]["body"]["parents"], ["folder-1"])
        self.assertEqual(docs.kwargs_for("documentId"), ["created-doc-id"])


class TestDocExistsErrorMapping(unittest.TestCase):
    """404 from files.get is ambiguous by Google's own documentation — it means
    'no read access OR does not exist'. Anything else must not be silently
    reinterpreted as 'missing', because the caller's response to False is to
    create a brand-new doc."""

    def test_readable_doc_is_true(self):
        self.assertTrue(doc_exists(FakeDrive(), "doc-abc"))

    def test_404_is_false(self):
        drive = FakeDrive()
        drive.get_error = HttpError(404, "File not found: doc-abc")
        self.assertFalse(doc_exists(drive, "doc-abc"))

    def test_403_raises_instead_of_reporting_missing(self):
        """A 403 here is a quota/domain-policy or sharing-restriction problem, not
        a missing file. Treating it as missing duplicates the content and buries
        the real error."""
        drive = FakeDrive()
        drive.get_error = HttpError(403, "insufficientFilePermissions")
        with self.assertRaises(HttpError) as ctx:
            doc_exists(drive, "doc-abc")
        self.assertEqual(ctx.exception.status_code, 403)

    def test_500_propagates(self):
        drive = FakeDrive()
        drive.get_error = HttpError(500, "Backend Error")
        with self.assertRaises(HttpError):
            doc_exists(drive, "doc-abc")


class TestUpdatePermissionError(unittest.TestCase):
    """403 insufficientFilePermissions on write is the read-yes/write-no case:
    files.get succeeded, so the doc is real and reachable. A raw traceback tells
    the user nothing about what to do."""

    def test_403_gives_actionable_message(self):
        drive = FakeDrive()
        drive.update_error = HttpError(
            403, "The user does not have sufficient permissions for file doc-abc"
        )
        with self.assertRaises(SystemExit) as ctx:
            update_doc(drive, "doc-abc", "/tmp/x.md", "Title")
        msg = str(ctx.exception)
        self.assertIn("doc-abc", msg)
        self.assertIn("--new", msg)

    def test_non_403_propagates(self):
        drive = FakeDrive()
        drive.update_error = HttpError(500, "Backend Error")
        with self.assertRaises(HttpError):
            update_doc(drive, "doc-abc", "/tmp/x.md", "Title")


if __name__ == "__main__":
    unittest.main()
