#!/usr/bin/env bash
# Strip YAML frontmatter, leading "Subject:" line(s), and Obsidian callout
# headers from a markdown file.
# Usage: clean.sh <input-file> <output-file>
set -euo pipefail

[[ $# -lt 2 ]] && { echo "Usage: $(basename "$0") <input> <output>" >&2; exit 1; }

awk '
  BEGIN {skip=0; seen_content=0}
  NR==1 && /^---$/ {skip=1; next}
  skip==1 && /^---$/ {skip=0; next}
  skip==1 {next}
  # Strip a leading "Subject: ..." line and any immediately following blank lines
  seen_content==0 && /^Subject:[[:space:]]/ {next}
  seen_content==0 && /^[[:space:]]*$/ {next}
  # Strip Obsidian callout headers like "> [!note]"
  /^> \[!.+\]/ {next}
  {seen_content=1; print}
' "$1" > "$2"
