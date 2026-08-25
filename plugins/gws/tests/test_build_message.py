"""Tests for the gmail-draft-from-markdown message builder.

build-message.py is the single source of truth for header composition across
both delivery routes — a base64 `raw` field passed inline, or an uploaded .eml
— so these assert that the two agree on headers and that each produces the
shape the Gmail API expects.

Routing is decided by encoded size, not by whether there are attachments,
because the limit being dodged is argv's. Both directions of that decision get
a case, and the shipped default threshold is exercised with the override unset.
"""

import base64
import email
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BUILDER = (
    Path(__file__).resolve().parents[1]
    / "skills"
    / "gmail-draft-from-markdown"
    / "scripts"
    / "build-message.py"
)


def run_builder(env, attachments=(), expect_success=True):
    """Run build-message.py and return (stdout, stderr, returncode)."""
    full_env = dict(os.environ)
    full_env.update({k: v for k, v in env.items() if v is not None})
    for key in ("TO", "SUBJECT", "CC", "BCC", "FROM", "IN_REPLY_TO",
                "REFERENCES", "THREAD_ID", "OUT_EML", "HTML_FILE",
                "MAX_JSON_BYTES"):
        if key not in env:
            full_env.pop(key, None)
    proc = subprocess.run(
        [sys.executable, str(BUILDER), *attachments],
        env=full_env,
        capture_output=True,
        text=True,
    )
    if expect_success and proc.returncode != 0:
        raise AssertionError(f"builder failed: {proc.stderr}")
    return proc.stdout, proc.stderr, proc.returncode


class BuildMessageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.html = self.dir / "body.html"
        self.html.write_text("<p>Hello <b>there</b></p>\n", encoding="utf-8")
        self.addCleanup(self.tmp.cleanup)

    def base_env(self, **overrides):
        env = {
            "TO": "alice@example.com",
            "SUBJECT": "Session recap",
            "HTML_FILE": str(self.html),
        }
        env.update(overrides)
        return env

    def upload_env(self, **overrides):
        """Force the upload route regardless of size (MAX_JSON_BYTES=0)."""
        env = self.base_env(OUT_EML=str(self.dir / "draft.eml"), MAX_JSON_BYTES="0")
        env.update(overrides)
        return env

    def parse_raw(self, stdout):
        payload = json.loads(stdout)
        raw = payload["message"]["raw"]
        # Gmail wants unpadded base64url; restore padding to decode.
        raw += "=" * (-len(raw) % 4)
        return payload, email.message_from_bytes(base64.urlsafe_b64decode(raw))

    # --- inline route ----------------------------------------------------

    def test_raw_mode_emits_headers_and_html_body(self):
        stdout, _, _ = run_builder(self.base_env())
        payload, msg = self.parse_raw(stdout)
        self.assertNotIn("threadId", payload["message"])
        self.assertEqual(msg["To"], "alice@example.com")
        self.assertEqual(msg["Subject"], "Session recap")
        self.assertTrue(msg["Date"], "Date header should always be set")
        self.assertEqual(msg.get_content_type(), "text/html")
        self.assertIn("Hello", msg.get_payload(decode=True).decode("utf-8"))

    def test_raw_mode_optional_headers_only_when_supplied(self):
        stdout, _, _ = run_builder(self.base_env())
        _, msg = self.parse_raw(stdout)
        for header in ("Cc", "Bcc", "From", "In-Reply-To", "References"):
            self.assertIsNone(msg[header], f"{header} should be absent")

        stdout, _, _ = run_builder(self.base_env(
            CC="carol@example.com",
            BCC="bob@example.com,dan@example.com",
            FROM="me@example.com",
        ))
        _, msg = self.parse_raw(stdout)
        self.assertEqual(msg["Cc"], "carol@example.com")
        self.assertEqual(msg["Bcc"], "bob@example.com,dan@example.com")
        self.assertEqual(msg["From"], "me@example.com")

    def test_raw_mode_threading_headers_and_thread_id(self):
        stdout, _, _ = run_builder(self.base_env(
            THREAD_ID="19f90b1dc3edfb44",
            IN_REPLY_TO="<parent@mail.example.com>",
            REFERENCES="<older@mail.example.com> <parent@mail.example.com>",
        ))
        payload, msg = self.parse_raw(stdout)
        self.assertEqual(payload["message"]["threadId"], "19f90b1dc3edfb44")
        self.assertEqual(msg["In-Reply-To"], "<parent@mail.example.com>")
        self.assertEqual(
            msg["References"],
            "<older@mail.example.com> <parent@mail.example.com>",
        )

    # --- upload route ----------------------------------------------------

    def test_upload_route_writes_file_and_prints_thread_metadata_only(self):
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.upload_env(THREAD_ID="19f90b1dc3edfb44"))
        self.assertEqual(
            json.loads(stdout), {"message": {"threadId": "19f90b1dc3edfb44"}}
        )
        msg = email.message_from_bytes(out.read_bytes())
        self.assertEqual(msg["To"], "alice@example.com")
        self.assertEqual(msg["Subject"], "Session recap")

    def test_upload_route_without_thread_prints_nothing(self):
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.upload_env())
        self.assertEqual(stdout.strip(), "")
        self.assertTrue(out.exists())

    def test_attachments_land_as_named_parts_alongside_the_html(self):
        one = self.dir / "agenda.pdf"
        one.write_bytes(b"%PDF-1.4 fake\n")
        two = self.dir / "notes.txt"
        two.write_text("plain notes\n", encoding="utf-8")
        out = self.dir / "draft.eml"

        run_builder(self.upload_env(), attachments=[str(one), str(two)])
        msg = email.message_from_bytes(out.read_bytes())

        self.assertEqual(msg.get_content_type(), "multipart/mixed")
        types = [p.get_content_type() for p in msg.walk()]
        self.assertIn("text/html", types)
        self.assertIn("application/pdf", types)
        self.assertIn("text/plain", types)
        names = [p.get_filename() for p in msg.walk() if p.get_filename()]
        self.assertEqual(names, ["agenda.pdf", "notes.txt"])
        pdf = next(p for p in msg.walk() if p.get_content_type() == "application/pdf")
        self.assertEqual(pdf.get_payload(decode=True), b"%PDF-1.4 fake\n")

    def test_attachment_basename_is_used_not_the_full_path(self):
        nested = self.dir / "sub"
        nested.mkdir()
        target = nested / "Vic Bliss Preliminary Plan.pdf"
        target.write_bytes(b"%PDF-1.4\n")
        out = self.dir / "draft.eml"
        run_builder(self.upload_env(), attachments=[str(target)])
        msg = email.message_from_bytes(out.read_bytes())
        names = [p.get_filename() for p in msg.walk() if p.get_filename()]
        self.assertEqual(names, ["Vic Bliss Preliminary Plan.pdf"])

    def test_unknown_extension_falls_back_to_octet_stream(self):
        blob = self.dir / "payload.weirdext"
        blob.write_bytes(b"\x00\x01\x02")
        out = self.dir / "draft.eml"
        run_builder(self.upload_env(), attachments=[str(blob)])
        msg = email.message_from_bytes(out.read_bytes())
        types = [p.get_content_type() for p in msg.walk()]
        self.assertIn("application/octet-stream", types)

    # --- routing (size decides, not attachments) --------------------------

    def big_html(self, size=200_000):
        """An HTML body large enough to overrun the inline threshold on its own."""
        self.html.write_text("<p>" + ("x" * size) + "</p>\n", encoding="utf-8")

    def test_small_message_goes_inline_even_though_a_path_is_available(self):
        # OUT_EML is offered but must be left alone: this message fits inline.
        # Runs with MAX_JSON_BYTES unset, so it exercises the shipped default.
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.base_env(OUT_EML=str(out)))
        _, msg = self.parse_raw(stdout)
        self.assertEqual(msg["To"], "alice@example.com")
        self.assertFalse(out.exists(), "small message must not take the upload route")

    def test_large_body_takes_the_upload_route_with_no_attachments(self):
        # The regression this guards: a long enough HTML body overruns argv on
        # its own, so routing cannot be gated on --attach. Default threshold.
        self.big_html()
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.base_env(
            OUT_EML=str(out), THREAD_ID="19f90b1dc3edfb44",
        ))
        self.assertEqual(
            json.loads(stdout), {"message": {"threadId": "19f90b1dc3edfb44"}}
        )
        self.assertTrue(out.exists(), "large message must take the upload route")
        msg = email.message_from_bytes(out.read_bytes())
        self.assertEqual(msg.get_content_type(), "text/html")
        self.assertNotIn("filename", str(msg))

    def test_large_attachments_take_the_upload_route_on_the_default(self):
        big = self.dir / "big.pdf"
        big.write_bytes(b"%PDF-1.4\n" + b"\x00" * 300_000)
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.base_env(OUT_EML=str(out)),
                                   attachments=[str(big)])
        self.assertEqual(stdout.strip(), "")
        msg = email.message_from_bytes(out.read_bytes())
        names = [p.get_filename() for p in msg.walk() if p.get_filename()]
        self.assertEqual(names, ["big.pdf"])

    def test_small_attachments_still_ride_inline(self):
        note = self.dir / "note.txt"
        note.write_text("tiny\n", encoding="utf-8")
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.base_env(OUT_EML=str(out)),
                                   attachments=[str(note)])
        _, msg = self.parse_raw(stdout)
        names = [p.get_filename() for p in msg.walk() if p.get_filename()]
        self.assertEqual(names, ["note.txt"])
        self.assertFalse(out.exists())

    def test_threshold_override_moves_the_boundary(self):
        out = self.dir / "draft.eml"
        stdout, _, _ = run_builder(self.base_env(
            OUT_EML=str(out), MAX_JSON_BYTES="200",
        ))
        self.assertEqual(stdout.strip(), "")
        self.assertTrue(out.exists(), "override must be able to force upload")

    def test_shipped_threshold_stays_under_the_linux_per_argument_cap(self):
        # Linux caps one argv string at MAX_ARG_STRLEN (32 pages = 131072),
        # whatever ARG_MAX is. The shipped default has to sit below that or the
        # inline route breaks on Linux while passing on macOS.
        source = BUILDER.read_text()
        line = next(l for l in source.splitlines()
                    if l.startswith("DEFAULT_MAX_JSON_BYTES"))
        value = int(line.split("=", 1)[1].strip().replace("_", ""))
        self.assertLess(value, 131072)

    # --- failure modes ---------------------------------------------------

    def test_missing_attachment_fails_with_a_readable_error(self):
        _, stderr, code = run_builder(
            self.upload_env(),
            attachments=[str(self.dir / "nope.pdf")],
            expect_success=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("Could not read attachment", stderr)

    def test_oversize_attachments_are_refused_before_the_api_call(self):
        big = self.dir / "big.bin"
        with big.open("wb") as fh:
            fh.truncate(26 * 1024 * 1024)
        _, stderr, code = run_builder(
            self.upload_env(),
            attachments=[str(big)],
            expect_success=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("25MB", stderr)

    def test_oversized_message_with_no_out_eml_path_fails_clearly(self):
        self.big_html()
        _, stderr, code = run_builder(self.base_env(), expect_success=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no OUT_EML path", stderr)

    def test_non_integer_threshold_fails(self):
        _, stderr, code = run_builder(
            self.base_env(MAX_JSON_BYTES="lots"), expect_success=False)
        self.assertNotEqual(code, 0)
        self.assertIn("MAX_JSON_BYTES", stderr)

    def test_missing_html_file_env_fails(self):
        _, stderr, code = run_builder({"TO": "a@b.c", "SUBJECT": "x"},
                                      expect_success=False)
        self.assertNotEqual(code, 0)
        self.assertIn("HTML_FILE", stderr)


if __name__ == "__main__":
    unittest.main()
