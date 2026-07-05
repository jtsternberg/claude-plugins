#!/usr/bin/env python3
"""Unit tests for docjson_to_md.py. Run:
python3 -m unittest discover -s plugins/gws/skills/google-doc-to-md/tests -p 'test_docjson_to_md.py' -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from docjson_to_md import tab_to_markdown  # noqa: E402


def para(text_runs, style="NORMAL_TEXT", bullet=None):
    elements = [{"textRun": {"content": t, "textStyle": s or {}}}
                for t, s in text_runs]
    p = {"paragraphStyle": {"namedStyleType": style}, "elements": elements}
    if bullet:
        p["bullet"] = bullet
    return {"paragraph": p}


def body(elements):
    return {"documentTab": {"body": {"content": elements}}}


class TestBasics(unittest.TestCase):
    def test_headings_and_text(self):
        md = tab_to_markdown(body([
            para([("Title\n", {})], style="HEADING_1"),
            para([("Body text\n", {})]),
            para([("Sub\n", {})], style="HEADING_2"),
        ]), lists={})
        self.assertEqual(md, "# Title\n\nBody text\n\n## Sub\n")

    def test_inline_styles(self):
        md = tab_to_markdown(body([
            para([("plain ", {}), ("bold", {"bold": True}),
                  (" ", {}), ("it", {"italic": True}),
                  (" ", {}),
                  ("lnk", {"link": {"url": "https://e.com"}}), ("\n", {})]),
        ]), lists={})
        self.assertEqual(md, "plain **bold** *it* [lnk](https://e.com)\n")

    def test_bullets(self):
        lists = {"L1": {"listProperties": {"nestingLevels": [
            {"glyphType": "GLYPH_TYPE_UNSPECIFIED"}]}}}
        md = tab_to_markdown(body([
            para([("one\n", {})], bullet={"listId": "L1"}),
            para([("sub\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
        ]), lists=lists)
        self.assertEqual(md, "- one\n  - sub\n")

    def test_numbered(self):
        lists = {"L1": {"listProperties": {"nestingLevels": [
            {"glyphType": "DECIMAL"}]}}}
        md = tab_to_markdown(body([
            para([("a\n", {})], bullet={"listId": "L1"}),
            para([("b\n", {})], bullet={"listId": "L1"}),
        ]), lists=lists)
        self.assertEqual(md, "1. a\n1. b\n")

    def test_table(self):
        cell = lambda t: {"content": [para([(t + "\n", {})])]}
        md = tab_to_markdown(body([
            {"table": {"rows": 2, "columns": 2, "tableRows": [
                {"tableCells": [cell("H1"), cell("H2")]},
                {"tableCells": [cell("a"), cell("b")]},
            ]}},
        ]), lists={})
        self.assertEqual(
            md, "| H1 | H2 |\n| --- | --- |\n| a | b |\n")


if __name__ == "__main__":
    unittest.main()
