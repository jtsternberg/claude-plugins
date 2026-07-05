#!/usr/bin/env python3
"""Unit tests for link_sections.py. Run:
python3 -m unittest discover -s plugins/gws/skills/md-to-google-doc/tests -p 'test_link_sections.py' -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from link_sections import (section_map, default_target,  # noqa: E402
                           build_link_requests)


def run(text, start, hid=None):
    el = {"startIndex": start, "endIndex": start + len(text),
          "textRun": {"content": text}}
    return el


def hpara(text, start, hid):
    return {"paragraph": {
        "paragraphStyle": {"namedStyleType": "HEADING_2", "headingId": hid},
        "elements": [run(text, start)]}}


def bpara(runs):
    return {"paragraph": {"paragraphStyle": {"namedStyleType": "NORMAL_TEXT"},
                          "elements": runs}}


def tab(tid, content):
    return {"tabProperties": {"tabId": tid},
            "documentTab": {"body": {"content": content}}}


FINDINGS = tab("t.0", [
    hpara("1. The headline\n", 1, "h.aaa"),
    hpara("3B. Alternative path\n", 20, "h.bbb"),
    hpara("8. Approvals\n", 50, "h.ccc"),
])


class TestSectionMap(unittest.TestCase):
    def test_extracts_numbered_headings(self):
        self.assertEqual(section_map(FINDINGS),
                         {"1": "h.aaa", "3B": "h.bbb", "8": "h.ccc"})


class TestDefaultTarget(unittest.TestCase):
    def test_picks_tab_with_most_numbered_headings(self):
        other = tab("t.notes", [bpara([run("see §3B\n", 1)])])
        self.assertEqual(default_target([other, FINDINGS]), "t.0")


class TestLinks(unittest.TestCase):
    def test_links_section_refs_cross_tab(self):
        notes = tab("t.notes", [
            bpara([run("Do the thing. ", 1), run("(§3B, §8)\n", 15)]),
        ])
        reqs = build_link_requests([FINDINGS, notes], target_tab_id="t.0")
        # two links: §3B and §8, both in the notes tab, pointing at t.0 headings
        self.assertEqual(len(reqs), 2)
        r0 = reqs[0]["updateTextStyle"]
        self.assertEqual(r0["range"]["tabId"], "t.notes")
        self.assertEqual(r0["textStyle"]["link"]["heading"],
                         {"id": "h.bbb", "tabId": "t.0"})
        self.assertEqual(r0["fields"], "link")
        # §3B occupies "(§3B" -> starts at index 16 (base 15 + offset 1)
        self.assertEqual(r0["range"]["startIndex"], 16)
        self.assertEqual(r0["range"]["endIndex"], 19)

    def test_unknown_section_is_skipped(self):
        notes = tab("t.notes", [bpara([run("nope §99\n", 1)])])
        reqs = build_link_requests([FINDINGS, notes], target_tab_id="t.0")
        self.assertEqual(reqs, [])

    def test_target_tab_itself_not_linked(self):
        # refs inside the target tab are left alone (default from = others)
        reqs = build_link_requests([FINDINGS], target_tab_id="t.0")
        self.assertEqual(reqs, [])


if __name__ == "__main__":
    unittest.main()
