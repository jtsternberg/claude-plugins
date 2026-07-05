#!/usr/bin/env python3
"""Turn §N / §NB section references into cross-tab heading links.

Usage: link_sections.py <doc.json> [--target <tab-id>] [--from <tab-id> ...]

Reads a documents.get(includeTabsContent=true) JSON. Builds a map of section
number -> headingId from the *target* tab's numbered headings ("3B. ...", "8.
..."), then emits updateTextStyle requests that link every §N reference in the
*from* tabs to the matching heading in the target tab (Docs Link.heading, which
is tab-aware). Prints {"requests": [...]}.

Defaults: target = the tab with the most numbered-section headings (the
"findings" tab); from = every other tab. References to sections with no
matching heading are left untouched.
"""
import json
import re
import sys

SECTION_RE = re.compile(r'§(\d+[A-Z]?)')
HEAD_RE = re.compile(r'^(\d+[A-Z]?)\.')


def _content(tab):
    return tab.get("documentTab", {}).get("body", {}).get("content", [])


def _ptext(p):
    return "".join(el.get("textRun", {}).get("content", "")
                   for el in p.get("elements", []))


def section_map(tab):
    """section number -> headingId, from the tab's numbered headings."""
    out = {}
    for e in _content(tab):
        p = e.get("paragraph")
        if not p:
            continue
        hid = p.get("paragraphStyle", {}).get("headingId")
        if not hid:
            continue
        m = HEAD_RE.match(_ptext(p).strip())
        if m:
            out[m.group(1)] = hid
    return out


def default_target(tabs):
    """The tab with the most numbered-section headings."""
    if not tabs:
        return None
    return max(tabs, key=lambda t: len(section_map(t)))["tabProperties"]["tabId"]


def _walk_paragraphs(content):
    for e in content:
        if "paragraph" in e:
            yield e["paragraph"]
        elif "table" in e:
            for row in e["table"].get("tableRows", []):
                for cell in row.get("tableCells", []):
                    yield from _walk_paragraphs(cell.get("content", []))


def build_link_requests(tabs, target_tab_id=None, from_tab_ids=None):
    by_id = {t["tabProperties"]["tabId"]: t for t in tabs}
    if target_tab_id is None:
        target_tab_id = default_target(tabs)
    secs = section_map(by_id[target_tab_id])
    if from_tab_ids is None:
        from_tab_ids = [tid for tid in by_id if tid != target_tab_id]
    reqs = []
    for tid in from_tab_ids:
        for p in _walk_paragraphs(_content(by_id[tid])):
            for el in p.get("elements", []):
                tr = el.get("textRun")
                if not tr:
                    continue
                base = el["startIndex"]
                for m in SECTION_RE.finditer(tr.get("content", "")):
                    hid = secs.get(m.group(1))
                    if not hid:
                        continue
                    reqs.append({"updateTextStyle": {
                        "range": {"startIndex": base + m.start(),
                                  "endIndex": base + m.end(), "tabId": tid},
                        "textStyle": {"link": {"heading": {
                            "id": hid, "tabId": target_tab_id}}},
                        "fields": "link"}})
    return reqs


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    doc = json.load(open(argv[1]))
    target = None
    from_ids = None
    if "--target" in argv:
        target = argv[argv.index("--target") + 1]
    if "--from" in argv:
        i = argv.index("--from") + 1
        from_ids = []
        while i < len(argv) and not argv[i].startswith("--"):
            from_ids.append(argv[i])
            i += 1
    reqs = build_link_requests(doc.get("tabs", []), target, from_ids)
    print(json.dumps({"requests": reqs}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
