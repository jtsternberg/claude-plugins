#!/usr/bin/env python3
"""Print how many Swift Characters (grapheme clusters) a payload file holds, or
print nothing when that cannot be known without a segmentation table.

cmux reports message_length as Swift's String.count, i.e. grapheme clusters. Bytes
(wc -c), codepoints (jq length) and shell ${#var} each differ from that for
non-ASCII text, so using any of them as the expected value would report byte loss
on a payload that arrived whole. Rather than approximate clusters, this counts
only text where one codepoint is one cluster, and declines the rest.

Declined: anything combining or joining (categories M*, Cf), emoji skin-tone
modifiers, regional-indicator pairs, Hangul jamo, the few letters that are
SpacingMark/Prepend, controls other than "\n" (so "\r\n" and tabs, which the
REPL may rewrite), and unassigned or private-use codepoints.

Leading and trailing whitespace is stripped first: a submitted prompt is not
guaranteed to keep it, and the check is one-sided (only a SHORTER report counts).
"""
import sys
import unicodedata

EXTRA_UNSAFE = {0x0D4E, 0x0E33, 0x0EB3, 0x111C2, 0x111C3, 0x11A3A, 0x11D46, 0x11F02}
UNSAFE_RANGES = (
    (0x1100, 0x11FF), (0xA960, 0xA97F), (0xD7B0, 0xD7FF),  # Hangul jamo
    (0x1F1E6, 0x1F1FF),                                    # regional indicators
    (0x1F3FB, 0x1F3FF),                                    # emoji modifiers
    (0x11A84, 0x11A89),
)


def safe(ch):
    o = ord(ch)
    if ch == "\n":
        return True
    if o in EXTRA_UNSAFE or any(a <= o <= b for a, b in UNSAFE_RANGES):
        return False
    return unicodedata.category(ch)[0] in "LNPSZ"


def main():
    try:
        # newline="" keeps "\r\n" as written; text mode would fold it into "\n".
        with open(sys.argv[1], encoding="utf-8", newline="") as f:
            text = f.read().strip()
    except (OSError, UnicodeDecodeError, IndexError):
        return
    if text and all(safe(c) for c in text):
        print(len(text))


main()
