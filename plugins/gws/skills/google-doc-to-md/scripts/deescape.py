#!/usr/bin/env python3
"""Unescape CommonMark backslash-escapes introduced by the claude.ai Google Drive
connector's read_file_content tool (an HTML->Markdown conversion step), while
leaving fenced code blocks and inline code spans untouched.

Usage:
    deescape.py < input.md > output.md
    deescape.py input.md output.md
"""
import re
import sys

# CommonMark's full escapable-punctuation set. The connector has been observed
# escaping a subset of these (#, *, [, ], ~, _, <, >, -) but we unescape the
# whole set since a generic HTML->MD converter commonly escapes all of it.
ESCAPABLE = r"\\`*_{}\[\]()#+\-.!<>|~"
ESCAPE_RE = re.compile(r"\\([" + ESCAPABLE + r"])")

FENCE_RE = re.compile(r"^(```|~~~)")
INLINE_CODE_RE = re.compile(r"(`+)(.*?)\1", re.DOTALL)


def _unescape_text(text):
    """Unescape backslash-escaped punctuation outside of inline code spans."""
    parts = []
    last = 0
    for m in INLINE_CODE_RE.finditer(text):
        # Unescape the segment before this code span, leave the span itself alone.
        parts.append(ESCAPE_RE.sub(r"\1", text[last:m.start()]))
        parts.append(m.group(0))
        last = m.end()
    parts.append(ESCAPE_RE.sub(r"\1", text[last:]))
    return "".join(parts)


def deescape_markdown(content):
    """Unescape connector backslash-escapes, skipping fenced code block bodies
    (whose content should never be touched) and inline code spans."""
    lines = content.split("\n")
    out = []
    in_fence = False
    fence_marker = None
    for line in lines:
        stripped = line.strip()
        if not in_fence and FENCE_RE.match(stripped):
            in_fence = True
            fence_marker = stripped[:3]
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            if stripped.startswith(fence_marker):
                in_fence = False
                fence_marker = None
            continue
        out.append(_unescape_text(line))
    return "\n".join(out)


def main():
    args = [a for a in sys.argv[1:] if a != "--"]
    if len(args) >= 2:
        with open(args[0], "r", encoding="utf-8") as f:
            content = f.read()
        result = deescape_markdown(content)
        with open(args[1], "w", encoding="utf-8") as f:
            f.write(result)
    elif len(args) == 1:
        with open(args[0], "r", encoding="utf-8") as f:
            content = f.read()
        sys.stdout.write(deescape_markdown(content))
    else:
        content = sys.stdin.read()
        sys.stdout.write(deescape_markdown(content))


if __name__ == "__main__":
    main()
