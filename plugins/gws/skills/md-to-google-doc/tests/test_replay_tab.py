#!/usr/bin/env python3
"""Unit tests for replay_tab.py request generation. Run:
python3 -m unittest plugins/gws/skills/md-to-google-doc/tests/test_replay_tab.py -v
(from repo root; test adds the scripts dir to sys.path)
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from replay_tab import build_requests  # noqa: E402

TAB = "t.testtab"


def para(start, runs, style="NORMAL_TEXT", bullet=None):
    """Build a paragraph structural element from (text, textStyle) runs."""
    elements, idx = [], start
    for text, tstyle in runs:
        elements.append({
            "startIndex": idx, "endIndex": idx + len(text),
            "textRun": {"content": text, "textStyle": tstyle or {}},
        })
        idx += len(text)
    p = {"paragraphStyle": {"namedStyleType": style}, "elements": elements}
    if bullet:
        p["bullet"] = bullet
    return {"startIndex": start, "endIndex": idx, "paragraph": p}


def doc(elements, lists=None):
    return {"body": {"content":
            [{"startIndex": 0, "endIndex": 1, "sectionBreak": {}}] + elements},
            "lists": lists or {}}


class TestClear(unittest.TestCase):
    def test_clear_emitted_when_tab_has_content(self):
        d = doc([para(1, [("\n", {})])])
        reqs = build_requests(d, TAB, clear_end=10)
        self.assertEqual(reqs[0], {"deleteContentRange": {"range": {
            "startIndex": 1, "endIndex": 9, "tabId": TAB}}})

    def test_no_clear_when_tab_empty(self):
        d = doc([para(1, [("\n", {})])])
        reqs = build_requests(d, TAB, clear_end=2)
        self.assertTrue(all("deleteContentRange" not in r for r in reqs))


class TestParagraphs(unittest.TestCase):
    def test_heading_then_body_with_bold(self):
        d = doc([
            para(1, [("Heading\n", {})], style="HEADING_1"),
            para(9, [("ab ", {"bold": True}), ("cd\n", {})]),
        ])
        reqs = build_requests(d, TAB, clear_end=2)
        # Insert heading text (with newline — not the last paragraph)
        self.assertIn({"insertText": {"location": {"index": 1, "tabId": TAB},
                                      "text": "Heading\n"}}, reqs)
        # Heading style over source range
        self.assertIn({"updateParagraphStyle": {
            "range": {"startIndex": 1, "endIndex": 9, "tabId": TAB},
            "paragraphStyle": {"namedStyleType": "HEADING_1"},
            "fields": "namedStyleType"}}, reqs)
        # Last paragraph: trailing newline skipped
        self.assertIn({"insertText": {"location": {"index": 9, "tabId": TAB},
                                      "text": "ab cd"}}, reqs)
        # Bold run styled over its source range
        self.assertIn({"updateTextStyle": {
            "range": {"startIndex": 9, "endIndex": 12, "tabId": TAB},
            "textStyle": {"bold": True}, "fields": "bold"}}, reqs)

    def test_link_style(self):
        d = doc([para(1, [("x\n", {"link": {"url": "https://e.com"}})])])
        reqs = build_requests(d, TAB, clear_end=2)
        style_reqs = [r for r in reqs if "updateTextStyle" in r]
        self.assertEqual(len(style_reqs), 1)
        self.assertEqual(style_reqs[0]["updateTextStyle"]["textStyle"],
                         {"link": {"url": "https://e.com"}})
        self.assertEqual(style_reqs[0]["updateTextStyle"]["fields"], "link")

    def test_empty_final_paragraph_inserts_nothing(self):
        d = doc([para(1, [("Hello\n", {})]), para(7, [("\n", {})])])
        reqs = build_requests(d, TAB, clear_end=2)
        inserts = [r["insertText"]["text"] for r in reqs if "insertText" in r]
        self.assertEqual(inserts, ["Hello\n"])


class TestBullets(unittest.TestCase):
    def _lists(self, glyph):
        return {"L1": {"listProperties": {"nestingLevels": [{"glyphType": glyph}]}}}

    def test_bullet_group_single_request(self):
        d = doc([
            para(1, [("one\n", {})], bullet={"listId": "L1"}),
            para(5, [("two\n", {})], bullet={"listId": "L1"}),
            para(9, [("after\n", {})]),
        ], lists=self._lists("GLYPH_TYPE_UNSPECIFIED"))
        reqs = build_requests(d, TAB, clear_end=2)
        bullets = [r for r in reqs if "createParagraphBullets" in r]
        self.assertEqual(len(bullets), 1)  # ONE request for the group
        self.assertEqual(bullets[0]["createParagraphBullets"]["bulletPreset"],
                         "BULLET_DISC_CIRCLE_SQUARE")
        # Range covers both paragraphs (no nesting → no tab padding)
        self.assertEqual(bullets[0]["createParagraphBullets"]["range"],
                         {"startIndex": 1, "endIndex": 9, "tabId": TAB})

    def test_numbered_preset(self):
        d = doc([para(1, [("one\n", {})], bullet={"listId": "L1"}),
                 para(5, [("\n", {})])],
                lists=self._lists("DECIMAL"))
        reqs = build_requests(d, TAB, clear_end=2)
        bullets = [r for r in reqs if "createParagraphBullets" in r]
        self.assertEqual(bullets[0]["createParagraphBullets"]["bulletPreset"],
                         "NUMBERED_DECIMAL_ALPHA_ROMAN")

    def test_nested_bullet_gets_tab_prefix_and_extended_range(self):
        d = doc([
            para(1, [("top\n", {})], bullet={"listId": "L1"}),
            para(5, [("sub\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
            para(9, [("\n", {})]),
        ], lists=self._lists("GLYPH_TYPE_UNSPECIFIED"))
        reqs = build_requests(d, TAB, clear_end=2)
        inserts = [r["insertText"]["text"] for r in reqs if "insertText" in r]
        self.assertIn("top\n", inserts)
        self.assertIn("\tsub\n", inserts)  # nesting via leading tab
        bullets = [r for r in reqs if "createParagraphBullets" in r][0]
        # group range 1..9 extended by the 1 inserted tab char
        self.assertEqual(bullets["createParagraphBullets"]["range"],
                         {"startIndex": 1, "endIndex": 10, "tabId": TAB})


class TestBulletOffset(unittest.TestCase):
    """Regression: inserted nesting-tabs must be accounted for in the index
    model, or items/headings after a nested item drift (bug z91m)."""
    def _lists(self):
        return {"L1": {"listProperties": {"nestingLevels": [
            {"glyphType": "GLYPH_TYPE_UNSPECIFIED"}]}}}

    def test_item_after_nested_item_inserts_at_correct_index(self):
        # group: a(lvl0), b(lvl1), c(lvl0). b inserts a leading tab, so c must
        # land at index 6 (after "a\n" + "\tb\n"), NOT 5.
        d = doc([
            para(1, [("a\n", {})], bullet={"listId": "L1"}),
            para(3, [("b\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
            para(5, [("c\n", {})], bullet={"listId": "L1"}),
            para(7, [("\n", {})]),
        ], lists=self._lists())
        reqs = build_requests(d, TAB, clear_end=2)
        inserts = {r["insertText"]["text"]: r["insertText"]["location"]["index"]
                   for r in reqs if "insertText" in r}
        self.assertEqual(inserts.get("\tb\n"), 3)
        self.assertEqual(inserts.get("c\n"), 6)

    def test_bulleted_paragraph_omits_indent_fields(self):
        # Source bullets carry auto-indent (indentStart/indentFirstLine) that
        # reflects their nesting. Replaying it on top of the nesting-tab makes
        # createParagraphBullets double-count depth (level 1 -> 2). The list
        # owns indentation, so indent fields must be dropped for bullets.
        d = doc([
            para(1, [("a\n", {})], bullet={"listId": "L1"}),
            para(3, [("b\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
            para(5, [("\n", {})]),
        ], lists=self._lists())
        d["body"]["content"][2]["paragraph"]["paragraphStyle"].update({
            "indentStart": {"magnitude": 72, "unit": "PT"},
            "indentFirstLine": {"magnitude": 54, "unit": "PT"}})
        reqs = build_requests(d, TAB, clear_end=2)
        for r in reqs:
            fields = r.get("updateParagraphStyle", {}).get("fields", "")
            self.assertNotIn("indentStart", fields)
            self.assertNotIn("indentFirstLine", fields)

    def test_emission_phase_order(self):
        # Contract: clear, then ALL inserts, then ALL styles, then
        # createParagraphBullets in REVERSE document order.
        d = doc([
            para(1, [("a\n", {})], bullet={"listId": "L1"}),
            para(3, [("b\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
            para(5, [("Head\n", {})], style="HEADING_2"),
            para(10, [("x\n", {})], bullet={"listId": "L2"}),
            para(12, [("\n", {})]),
        ], lists={"L1": self._lists()["L1"], "L2": self._lists()["L1"]})
        reqs = build_requests(d, TAB, clear_end=5)
        kinds = [next(iter(r)) for r in reqs]
        self.assertEqual(kinds[0], "deleteContentRange")
        inserts = [i for i, k in enumerate(kinds)
                   if k in ("insertText", "insertTable")]
        styles = [i for i, k in enumerate(kinds)
                  if k in ("updateTextStyle", "updateParagraphStyle")]
        bullets = [i for i, k in enumerate(kinds)
                   if k == "createParagraphBullets"]
        self.assertLess(max(inserts), min(styles))      # all inserts before styles
        self.assertLess(max(styles), min(bullets))      # all styles before bullets
        # bullets emitted in reverse: the L2 group (later in doc) comes first
        self.assertEqual(len(bullets), 2)


class TestTables(unittest.TestCase):
    def _table_doc(self):
        # "P\n" (1-3), table (3-13): 1 row × 1 col, cell text "x\n", then "\n" (13-14)
        # Index skeleton for a 1x1 table starting at 3:
        #   3 table start, 4 row start, 5 cell start, cell paragraph "x\n" at 5-7,
        #   table endIndex 8... exact skeleton numbers matter only for OUR fixture
        # consistency: the generator reads whatever indices the fixture declares.
        cell_para = para(5, [("x\n", {})])
        return doc([
            para(1, [("P\n", {})]),
            {"startIndex": 3, "endIndex": 8, "table": {
                "rows": 1, "columns": 1,
                "tableRows": [{"startIndex": 4, "endIndex": 8, "tableCells": [
                    {"startIndex": 5, "endIndex": 8, "content": [cell_para]},
                ]}]}},
            para(8, [("\n", {})]),
        ])

    def test_table_replay(self):
        reqs = build_requests(self._table_doc(), TAB, clear_end=2)
        # Paragraph before table loses its newline (insertTable provides it)
        self.assertIn({"insertText": {"location": {"index": 1, "tabId": TAB},
                                      "text": "P"}}, reqs)
        self.assertIn({"insertTable": {"rows": 1, "columns": 1,
                       "location": {"index": 2, "tabId": TAB}}}, reqs)
        # Cell text inserted at source index, final cell newline skipped
        self.assertIn({"insertText": {"location": {"index": 5, "tabId": TAB},
                                      "text": "x"}}, reqs)
        # Ordering: para text before table, table before cell text
        kinds = [next(iter(r)) for r in reqs]
        self.assertLess(kinds.index("insertTable"),
                        [i for i, r in enumerate(reqs)
                         if r.get("insertText", {}).get("text") == "x"][0])


class TestHorizontalRule(unittest.TestCase):
    def _hr_doc(self):
        return doc([
            para(1, [("Above\n", {})]),
            {"startIndex": 7, "endIndex": 9, "paragraph": {
                "paragraphStyle": {"namedStyleType": "NORMAL_TEXT"},
                "elements": [
                    {"startIndex": 7, "endIndex": 8, "horizontalRule": {}},
                    {"startIndex": 8, "endIndex": 9,
                     "textRun": {"content": "\n", "textStyle": {}}}]}},
            para(9, [("Below\n", {})]),
        ])

    def test_hr_becomes_border_paragraph(self):
        reqs = build_requests(self._hr_doc(), TAB, clear_end=2)
        borders = [r for r in reqs
                   if r.get("updateParagraphStyle", {}).get("fields") == "borderBottom"]
        self.assertEqual(len(borders), 1)
        # the border paragraph sits where the HR was (index 7), spanning its "\n"
        rng = borders[0]["updateParagraphStyle"]["range"]
        self.assertEqual(rng["tabId"], TAB)
        # "Below" still follows correctly (mirror preserved: Above\n + \n = index 9)
        self.assertIn({"insertText": {"location": {"index": 8, "tabId": TAB},
                                      "text": "Below"}}, reqs)


class TestSkips(unittest.TestCase):
    def test_inline_object_skipped(self):
        d = doc([{"startIndex": 1, "endIndex": 3, "paragraph": {
            "paragraphStyle": {"namedStyleType": "NORMAL_TEXT"},
            "elements": [
                {"startIndex": 1, "endIndex": 2,
                 "inlineObjectElement": {"inlineObjectId": "obj1"}},
                {"startIndex": 2, "endIndex": 3,
                 "textRun": {"content": "\n", "textStyle": {}}},
            ]}}])
        reqs = build_requests(d, TAB, clear_end=2)  # must not raise
        inserts = [r["insertText"]["text"] for r in reqs if "insertText" in r]
        self.assertEqual(inserts, [])  # image dropped, final newline skipped


if __name__ == "__main__":
    unittest.main()
