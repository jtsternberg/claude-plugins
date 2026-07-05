#!/usr/bin/env python3
"""Generate Docs batchUpdate requests that replay a source document's body
into a target tab.

Usage: replay_tab.py <source-doc.json> <target-tab-id> [--clear-end N]

Reads the documents.get JSON of a single-tab source doc (body at top level),
prints {"requests": [...]} to stdout. All requests carry the target tabId.
If --clear-end N is given and N > 2, a deleteContentRange for 1..N-1 is
emitted first (empties the target tab; index 0 and the final newline are
un-deletable).

Emission order matters because Docs applies requests sequentially:
  1. clear (optional)          — empty the target tab
  2. all inserts               — insertText / insertTable, in document order
  3. all styling               — updateTextStyle / updateParagraphStyle
  4. all createParagraphBullets — in REVERSE document order

Inserting everything first means styling ranges are computed against the
final "content + nesting-tabs" layout and applied while it still holds.
createParagraphBullets runs last (it deletes the leading nesting-tabs), in
reverse so a later group's tab-removal never shifts an earlier group's range.

Index model: target index = source index + offset, where offset accumulates
+1 per inserted nesting tab and -N per skipped element (image/HR/chip). The
tabs are NOT removed from the model — they exist in the layout that phases 2-4
operate on; only the final createParagraphBullets pass deletes them.
"""
import json
import sys

UNORDERED_GLYPHS = {"GLYPH_TYPE_UNSPECIFIED", "NONE", ""}
BULLET_UNORDERED = "BULLET_DISC_CIRCLE_SQUARE"
BULLET_ORDERED = "NUMBERED_DECIMAL_ALPHA_ROMAN"

# textStyle fields we replay (order fixed for deterministic "fields" strings)
TEXT_STYLE_FIELDS = ["bold", "italic", "underline", "strikethrough",
                     "baselineOffset", "fontSize", "weightedFontFamily",
                     "foregroundColor", "backgroundColor", "link"]
PARA_STYLE_FIELDS = ["namedStyleType", "alignment", "indentStart",
                     "indentEnd", "indentFirstLine", "spaceAbove",
                     "spaceBelow"]
# Indent is auto-derived from bullet nesting; replaying it on a bulleted
# paragraph makes createParagraphBullets double-count depth, so drop it there.
PARA_INDENT_FIELDS = ("indentStart", "indentEnd", "indentFirstLine")

# Docs has no "insert horizontal rule" request; a paragraph bottom border is
# the standard thematic-break equivalent (what Docs itself uses).
HR_BORDER = {"borderBottom": {
    "color": {"color": {"rgbColor": {"red": 0.6, "green": 0.6, "blue": 0.6}}},
    "width": {"magnitude": 1, "unit": "PT"},
    "padding": {"magnitude": 0, "unit": "PT"},
    "dashStyle": "SOLID"}}


def warn(msg):
    print("WARNING: %s" % msg, file=sys.stderr)


class Replayer:
    def __init__(self, doc, tab_id):
        self.doc = doc
        self.tab = tab_id
        self.inserts = []   # phase 2
        self.styles = []    # phase 3
        self.bullets = []   # phase 4 (emitted in reverse)
        self.offset = 0     # target index = source index + offset

    # -- helpers ----------------------------------------------------------
    def t(self, src_index):
        return src_index + self.offset

    def bullet_preset(self, list_id):
        props = (self.doc.get("lists", {}).get(list_id, {})
                 .get("listProperties", {}))
        levels = props.get("nestingLevels") or [{}]
        glyph = levels[0].get("glyphType", "")
        if glyph in UNORDERED_GLYPHS or "glyphSymbol" in levels[0]:
            return BULLET_UNORDERED
        return BULLET_ORDERED

    def filtered_style(self, style, allowed):
        picked = {k: style[k] for k in allowed if k in style}
        return picked, ",".join(k for k in allowed if k in style)

    # -- paragraph --------------------------------------------------------
    def paragraph_text(self, p_elem):
        """Concatenated textRun content; warns on skipped element kinds and
        adjusts offset for the dropped indices."""
        parts = []
        for el in p_elem["paragraph"].get("elements", []):
            if "textRun" in el:
                parts.append(el["textRun"].get("content", ""))
            else:
                kind = next((k for k in el if k not in
                             ("startIndex", "endIndex")), "unknown")
                # horizontalRule is handled (rendered as a bottom border), not
                # skipped — don't warn for it.
                if kind != "horizontalRule":
                    warn("skipped unsupported element '%s' at index %s"
                         % (kind, el.get("startIndex")))
                self.offset -= (el.get("endIndex", 0)
                                - el.get("startIndex", 0))
        return "".join(parts)

    @staticmethod
    def is_hr(p_elem):
        return any("horizontalRule" in el
                   for el in p_elem["paragraph"].get("elements", []))

    def replay_paragraph(self, p_elem, drop_trailing_newline, tab_prefix=0):
        # Compute the insert position BEFORE paragraph_text mutates offset for
        # any in-paragraph skips: the paragraph's text lands at its start.
        insert_at = self.t(p_elem["startIndex"])
        text = self.paragraph_text(p_elem)
        if drop_trailing_newline and text.endswith("\n"):
            text = text[:-1]
        text = "\t" * tab_prefix + text
        if text:
            self.inserts.append({"insertText": {
                "location": {"index": insert_at, "tabId": self.tab},
                "text": text}})
        # Paragraph target span, anchored to the actual insert position (robust
        # to in-paragraph skips that shift self.offset). Used for paragraph-level
        # style + HR border ranges.
        para_start = insert_at
        para_end = max(insert_at + len(text), insert_at + 1)
        # Per-run text styles (source ranges + offset + tab prefix; clamp off
        # the dropped trailing newline).
        for el in p_elem["paragraph"].get("elements", []):
            if "textRun" not in el:
                continue
            style, fields = self.filtered_style(
                el["textRun"].get("textStyle", {}), TEXT_STYLE_FIELDS)
            if not fields:
                continue
            start, end = el["startIndex"], el["endIndex"]
            if drop_trailing_newline and end == p_elem["endIndex"]:
                end -= 1
            if end <= start:
                continue
            self.styles.append({"updateTextStyle": {
                "range": {"startIndex": self.t(start) + tab_prefix,
                          "endIndex": self.t(end) + tab_prefix,
                          "tabId": self.tab},
                "textStyle": style, "fields": fields}})
        # Paragraph style (skip plain NORMAL_TEXT with no other props). Drop
        # indent fields on bulleted paragraphs — see PARA_INDENT_FIELDS.
        allowed = PARA_STYLE_FIELDS
        if p_elem["paragraph"].get("bullet"):
            allowed = [f for f in PARA_STYLE_FIELDS
                       if f not in PARA_INDENT_FIELDS]
        pstyle, pfields = self.filtered_style(
            p_elem["paragraph"].get("paragraphStyle", {}), allowed)
        if pfields and not (pfields == "namedStyleType"
                            and pstyle.get("namedStyleType") == "NORMAL_TEXT"):
            self.styles.append({"updateParagraphStyle": {
                "range": {"startIndex": para_start, "endIndex": para_end,
                          "tabId": self.tab},
                "paragraphStyle": pstyle, "fields": pfields}})
        # Horizontal rule -> render the (empty) paragraph with a bottom border.
        if self.is_hr(p_elem):
            self.styles.append({"updateParagraphStyle": {
                "range": {"startIndex": para_start, "endIndex": para_end,
                          "tabId": self.tab},
                "paragraphStyle": HR_BORDER, "fields": "borderBottom"}})

    # -- containers -------------------------------------------------------
    def replay_container(self, content):
        """Replay a list of structural elements (body or a table cell).
        The container's final newline already exists in the target."""
        i = 0
        elems = [e for e in content if "sectionBreak" not in e]
        while i < len(elems):
            e = elems[i]
            is_last = (i == len(elems) - 1)
            if "table" in e:
                self.replay_table(e)
                i += 1
            elif "paragraph" in e and e["paragraph"].get("bullet"):
                # Collect the group of consecutive paragraphs sharing a
                # bullet listId so numbered lists get ONE createParagraphBullets
                # request (continuous numbering).
                list_id = e["paragraph"]["bullet"].get("listId")
                group = []
                while (i < len(elems) and "paragraph" in elems[i]
                       and elems[i]["paragraph"].get("bullet", {})
                       .get("listId") == list_id):
                    group.append((elems[i], i == len(elems) - 1))
                    i += 1
                off0 = self.offset  # offset at the group's first paragraph
                for p_elem, last in group:
                    lvl = (p_elem["paragraph"]["bullet"]
                           .get("nestingLevel", 0))
                    self.replay_paragraph(p_elem, drop_trailing_newline=last,
                                          tab_prefix=lvl)
                    # Track each inserted nesting tab; createParagraphBullets
                    # (phase 4, reversed) deletes them later.
                    self.offset += lvl
                self.bullets.append({"createParagraphBullets": {
                    "range": {"startIndex": group[0][0]["startIndex"] + off0,
                              "endIndex": self.t(group[-1][0]["endIndex"]),
                              "tabId": self.tab},
                    "bulletPreset": self.bullet_preset(list_id)}})
            elif "paragraph" in e:
                # A paragraph immediately followed by a table loses its trailing
                # newline (insertTable supplies one before the table).
                next_is_table = (i + 1 < len(elems)
                                 and "table" in elems[i + 1])
                self.replay_paragraph(
                    e, drop_trailing_newline=is_last or next_is_table)
                i += 1
            else:
                kind = next((k for k in e if k not in
                             ("startIndex", "endIndex")), "unknown")
                warn("skipped structural element '%s'" % kind)
                self.offset -= e["endIndex"] - e["startIndex"]
                i += 1

    def replay_table(self, t_elem):
        table = t_elem["table"]
        self.inserts.append({"insertTable": {
            "rows": table["rows"], "columns": table["columns"],
            "location": {"index": self.t(t_elem["startIndex"]) - 1,
                         "tabId": self.tab}}})
        for row in table.get("tableRows", []):
            for cell in row.get("tableCells", []):
                self.replay_container(cell.get("content", []))

    # -- entry ------------------------------------------------------------
    def run(self, clear_end):
        reqs = []
        if clear_end and clear_end > 2:
            reqs.append({"deleteContentRange": {"range": {
                "startIndex": 1, "endIndex": clear_end - 1,
                "tabId": self.tab}}})
        self.replay_container(self.doc["body"]["content"])
        # Phase order: clear, inserts, styles, bullets (reverse doc order).
        return reqs + self.inserts + self.styles + list(reversed(self.bullets))


def build_requests(doc, tab_id, clear_end=0):
    return Replayer(doc, tab_id).run(clear_end)


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 1
    with open(argv[1]) as f:
        doc = json.load(f)
    tab_id = argv[2]
    clear_end = 0
    if "--clear-end" in argv:
        clear_end = int(argv[argv.index("--clear-end") + 1])
    print(json.dumps({"requests": build_requests(doc, tab_id, clear_end)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
