#!/usr/bin/env bash
# Strip YAML frontmatter and Obsidian callout headers from a markdown file.
# Usage: clean.sh <input-file> <output-file>
# Creates output-file with cleaned content. Caller is responsible for cleanup.
set -euo pipefail

[[ $# -lt 2 ]] && { echo "Usage: $(basename "$0") <input> <output>" >&2; exit 1; }

awk '
  BEGIN {skip=0}
  NR==1 && /^---$/ {skip=1; next}
  skip==1 && /^---$/ {skip=0; next}
  skip==0 && /^> \[!.+\]/ {next}
  skip==0 {print}
' "$1" > "$2"
