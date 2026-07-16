#!/usr/bin/env python3
"""Unit tests for deescape.py. Run: python3 tests/test_deescape.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from deescape import deescape_markdown  # noqa: E402


class TestDeescape(unittest.TestCase):
    def test_heading_hash(self):
        self.assertEqual(deescape_markdown(r"\# Heading"), "# Heading")

    def test_issue_reference(self):
        self.assertEqual(deescape_markdown(r"Fixed in \#687"), "Fixed in #687")

    def test_bold_and_italic(self):
        self.assertEqual(deescape_markdown(r"\*\*bold\*\* and \_italic\_"), "**bold** and _italic_")

    def test_links(self):
        self.assertEqual(
            deescape_markdown(r"\[link text\]\(https://example.com\)"),
            "[link text](https://example.com)",
        )

    def test_strikethrough_and_lt_gt(self):
        self.assertEqual(deescape_markdown(r"\~\~gone\~\~ and \<tag\> \> quote"), "~~gone~~ and <tag> > quote")

    def test_list_dash(self):
        self.assertEqual(deescape_markdown(r"\- item one"), "- item one")

    def test_multiline_document(self):
        src = "\\# Title\n\nSome \\*emphasis\\* and a \\[link\\]\\(url\\).\n\n\\- bullet\n\\- another"
        expected = "# Title\n\nSome *emphasis* and a [link](url).\n\n- bullet\n- another"
        self.assertEqual(deescape_markdown(src), expected)

    def test_fenced_code_block_untouched(self):
        src = "Before \\#1\n```\nliteral \\# in code\n```\nAfter \\#2"
        expected = "Before #1\n```\nliteral \\# in code\n```\nAfter #2"
        self.assertEqual(deescape_markdown(src), expected)

    def test_tilde_fence_untouched(self):
        src = "~~~\nkeep \\* literal\n~~~"
        self.assertEqual(deescape_markdown(src), src)

    def test_inline_code_span_untouched(self):
        src = "Run `git \\* status` please, but unescape \\* here."
        expected = "Run `git \\* status` please, but unescape * here."
        self.assertEqual(deescape_markdown(src), expected)

    def test_table_pipe_and_bar(self):
        src = r"| a \| b | c \| d |"
        expected = "| a | b | c | d |"
        self.assertEqual(deescape_markdown(src), expected)

    def test_no_escapes_is_noop(self):
        src = "# Plain heading\n\nNo escapes here. Just *actual* markdown and a [link](url)."
        self.assertEqual(deescape_markdown(src), src)

    def test_literal_double_backslash_preserved_as_single(self):
        # A literal backslash followed by an escapable char is indistinguishable
        # from a connector escape - this is the known, documented limitation.
        self.assertEqual(deescape_markdown(r"C:\\Program Files \* test"), r"C:\Program Files * test")

    def test_period_and_bang_and_plus(self):
        self.assertEqual(deescape_markdown(r"1\. First\!  a \+ b"), "1. First!  a + b")

    def test_smoke_test_fixture(self):
        # Verbatim excerpts from the connector live smoke test against a real
        # work-account doc (see /tmp/gdoc-connector-smoke-results.md, 2026-07-14):
        # download_file_content(exportMimeType: text/markdown) returned these
        # backslash-escaped lines.
        src = (
            r"# \[TEMPLATE\] Quarterly Review"
            "\n\n"
            r"debugging real \#lindris-onboarding tickets"
            "\n\n"
            r"March 20 bulk-enrollment epic ([\#687](https://example.com/issues/687))"
        )
        expected = (
            "# [TEMPLATE] Quarterly Review"
            "\n\n"
            "debugging real #lindris-onboarding tickets"
            "\n\n"
            "March 20 bulk-enrollment epic ([#687](https://example.com/issues/687))"
        )
        self.assertEqual(deescape_markdown(src), expected)

    def test_equals_and_other_commonmark_punctuation(self):
        # \= observed live in a real connector export (2026-07-14, "commits
        # with ≤1 parent \= non-merge") — the connector escapes beyond the
        # originally-observed set, so we cover CommonMark's full set.
        self.assertEqual(
            deescape_markdown(r"parent \= non-merge; a\=b \& c\; \:x \"q\" \@u \$5 \%p \^v \?y \,z \/w \'s"),
            'parent = non-merge; a=b & c; :x "q" @u $5 %p ^v ?y ,z /w \'s',
        )


if __name__ == "__main__":
    unittest.main()
