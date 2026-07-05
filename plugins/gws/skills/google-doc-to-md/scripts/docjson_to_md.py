#!/usr/bin/env python3
"""Convert one tab of a documents.get(includeTabsContent=true) JSON to markdown.

Usage: docjson_to_md.py <doc.json> <tab-id>
Prints markdown to stdout. Supports headings, bold/italic/strikethrough,
links, bullet/numbered lists (with nesting), and tables. Everything else
degrades to plain text.
"""
import json
import sys

HEADINGS = {"HEADING_1": "#", "HEADING_2": "##", "HEADING_3": "###",
            "HEADING_4": "####", "HEADING_5": "#####", "HEADING_6": "######",
            "TITLE": "#"}
UNORDERED_GLYPHS = {"GLYPH_TYPE_UNSPECIFIED", "NONE", ""}


def run_to_md(run):
    text = run.get("textRun", {}).get("content", "")
    style = run.get("textRun", {}).get("textStyle", {})
    stripped = text.rstrip("\n")
    trailing = text[len(stripped):]
    if not stripped:
        return text
    out = stripped
    if style.get("bold"):
        out = "**%s**" % out
    if style.get("italic"):
        out = "*%s*" % out
    if style.get("strikethrough"):
        out = "~~%s~~" % out
    if style.get("link", {}).get("url"):
        out = "[%s](%s)" % (out, style["link"]["url"])
    return out + trailing


def para_text(p):
    return "".join(run_to_md(el) for el in p.get("elements", [])
                   if "textRun" in el).rstrip("\n")


def is_ordered(lists, list_id):
    levels = (lists.get(list_id, {}).get("listProperties", {})
              .get("nestingLevels") or [{}])
    glyph = levels[0].get("glyphType", "")
    return glyph not in UNORDERED_GLYPHS and "glyphSymbol" not in levels[0]


def content_to_md(content, lists):
    blocks = []
    prev_kind = None  # "list" | "para" | "table"
    for e in content:
        if "paragraph" in e:
            p = e["paragraph"]
            text = para_text(p)
            bullet = p.get("bullet")
            if bullet:
                indent = "  " * bullet.get("nestingLevel", 0)
                marker = "1." if is_ordered(lists, bullet.get("listId")) else "-"
                line = "%s%s %s" % (indent, marker, text)
                if prev_kind == "list":
                    blocks[-1] += "\n" + line
                else:
                    blocks.append(line)
                prev_kind = "list"
            else:
                if not text:
                    continue
                style = p.get("paragraphStyle", {}).get("namedStyleType", "")
                prefix = HEADINGS.get(style)
                blocks.append(("%s %s" % (prefix, text)) if prefix else text)
                prev_kind = "para"
        elif "table" in e:
            rows = []
            for row in e["table"].get("tableRows", []):
                cells = [" ".join(
                    para_text(c["paragraph"])
                    for c in cell.get("content", []) if "paragraph" in c
                ).strip() for cell in row.get("tableCells", [])]
                rows.append("| %s |" % " | ".join(cells))
            if rows:
                sep = "| %s |" % " | ".join(
                    ["---"] * e["table"].get("columns", 1))
                blocks.append("\n".join([rows[0], sep] + rows[1:]))
            prev_kind = "table"
    return "\n\n".join(blocks) + "\n" if blocks else ""


def tab_to_markdown(tab, lists):
    return content_to_md(tab["documentTab"]["body"]["content"], lists)


def find_tab(tabs, tab_id):
    for t in tabs or []:
        if t.get("tabProperties", {}).get("tabId") == tab_id:
            return t
        hit = find_tab(t.get("childTabs"), tab_id)
        if hit:
            return hit


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    with open(argv[1]) as f:
        doc = json.load(f)
    tab = find_tab(doc.get("tabs"), argv[2])
    if not tab:
        print("ERROR: tab not found: %s" % argv[2], file=sys.stderr)
        return 1
    lists = tab.get("documentTab", {}).get("lists", {}) or doc.get("lists", {})
    sys.stdout.write(tab_to_markdown(tab, lists))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
