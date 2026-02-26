#!/usr/bin/env bash
# Validate a slide presentation HTML file for common issues
# Compatible with macOS (BSD grep) and Linux (GNU grep)
set -euo pipefail

FILE="${1:?Usage: validate-presentation.sh <file.html>}"
ERRORS=0
WARNINGS=0

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE"
  exit 1
fi

# Check for unreplaced template placeholders
if grep -qE '\{\{[A-Z_]+\}\}' "$FILE"; then
  echo "ERROR: Unreplaced template placeholders found:"
  grep -oE '\{\{[A-Z_]+\}\}' "$FILE" | sort -u | sed 's/^/  /'
  ERRORS=$((ERRORS + 1))
fi

# Extract data-slide numbers using sed (portable)
SLIDES=$(grep -oE 'data-slide="[0-9]+"' "$FILE" | sed 's/data-slide="//;s/"//' | sort -n)
if [[ -z "$SLIDES" ]]; then
  echo "ERROR: No data-slide attributes found"
  ERRORS=$((ERRORS + 1))
  SLIDE_COUNT=0
else
  EXPECTED=0
  while IFS= read -r n; do
    if [[ "$n" -ne "$EXPECTED" ]]; then
      echo "ERROR: data-slide gap: expected $EXPECTED, found $n"
      ERRORS=$((ERRORS + 1))
    fi
    EXPECTED=$((EXPECTED + 1))
  done <<< "$SLIDES"
  SLIDE_COUNT=$EXPECTED
fi

# Check slide counter matches actual slide count
COUNTER_LINE=$(grep -oE '1 */ *[0-9]+' "$FILE" | head -1 || true)
if [[ -n "$COUNTER_LINE" ]]; then
  COUNTER_TOTAL=$(echo "$COUNTER_LINE" | sed 's/.*\///' | tr -d ' ')
  if [[ "$COUNTER_TOTAL" -ne "$SLIDE_COUNT" ]]; then
    echo "ERROR: Slide counter says '1 / $COUNTER_TOTAL' but found $SLIDE_COUNT slides"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Check initial progress bar width matches slide count
if [[ "$SLIDE_COUNT" -gt 0 ]]; then
  EXPECTED_WIDTH=$(awk "BEGIN {printf \"%.0f\", 100 / $SLIDE_COUNT}")
  PROGRESS_LINE=$(grep 'id="progress"' "$FILE" || true)
  if [[ -n "$PROGRESS_LINE" ]]; then
    ACTUAL_WIDTH=$(echo "$PROGRESS_LINE" | grep -oE 'width: *[0-9]+%' | grep -oE '[0-9]+' || true)
    if [[ -n "$ACTUAL_WIDTH" ]] && [[ "$ACTUAL_WIDTH" -ne "$EXPECTED_WIDTH" ]]; then
      echo "WARNING: Progress bar initial width is ${ACTUAL_WIDTH}% but should be ~${EXPECTED_WIDTH}% for $SLIDE_COUNT slides"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# Check first slide has "active" class
if grep -q 'data-slide="0"' "$FILE"; then
  FIRST_SLIDE_LINE=$(grep 'data-slide="0"' "$FILE")
  if ! echo "$FIRST_SLIDE_LINE" | grep -q 'active'; then
    echo "WARNING: First slide (data-slide=\"0\") may not have 'active' class"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# Check slides have dark/light classes
DARK_COUNT=$(grep -c 'class="slide dark' "$FILE" || true)
LIGHT_COUNT=$(grep -c 'class="slide light' "$FILE" || true)
CLASSIFIED=$((DARK_COUNT + LIGHT_COUNT))
if [[ "$SLIDE_COUNT" -gt 0 ]] && [[ "$CLASSIFIED" -lt "$SLIDE_COUNT" ]]; then
  MISSING=$((SLIDE_COUNT - CLASSIFIED))
  echo "WARNING: $MISSING slide(s) missing dark/light class (found $DARK_COUNT dark, $LIGHT_COUNT light)"
  WARNINGS=$((WARNINGS + 1))
fi
if [[ "$DARK_COUNT" -gt 0 ]] && [[ "$LIGHT_COUNT" -eq 0 ]] && [[ "$SLIDE_COUNT" -gt 2 ]]; then
  echo "WARNING: All slides are dark — consider alternating dark/light for visual rhythm"
  WARNINGS=$((WARNINGS + 1))
fi
if [[ "$LIGHT_COUNT" -gt 0 ]] && [[ "$DARK_COUNT" -eq 0 ]] && [[ "$SLIDE_COUNT" -gt 2 ]]; then
  echo "WARNING: All slides are light — consider alternating dark/light for visual rhythm"
  WARNINGS=$((WARNINGS + 1))
fi

# Check slides have slide-content wrapper (needed for entry animations)
CONTENT_WRAPPERS=$(grep -c 'class="slide-content"' "$FILE" || true)
if [[ "$SLIDE_COUNT" -gt 0 ]] && [[ "$CONTENT_WRAPPERS" -lt "$SLIDE_COUNT" ]]; then
  MISSING=$((SLIDE_COUNT - CONTENT_WRAPPERS))
  echo "WARNING: $MISSING slide(s) missing .slide-content wrapper (entry animations won't work)"
  WARNINGS=$((WARNINGS + 1))
fi

# Check for banned generic fonts
if grep -qE "font-family:.*\b(Inter|Roboto|Arial|Helvetica)\b" "$FILE" 2>/dev/null; then
  echo "WARNING: Generic font detected (Inter/Roboto/Arial/Helvetica) — use a distinctive display + body pairing"
  WARNINGS=$((WARNINGS + 1))
fi

# Check for broken relative image paths (skip HTML comments)
DIR=$(dirname "$FILE")
# Strip HTML comments before searching for image references
IMAGES=$(sed 's/<!--.*-->//g' "$FILE" | grep -oE 'src="[^"]+\.(png|jpg|jpeg|svg|gif|webp)"' | sed 's/src="//;s/"$//' || true)
if [[ -n "$IMAGES" ]]; then
  while IFS= read -r img; do
    # Skip data URIs and absolute URLs
    if [[ "$img" == data:* ]] || [[ "$img" == http* ]]; then
      continue
    fi
    if [[ ! -f "$DIR/$img" ]]; then
      echo "WARNING: Image not found: $img (relative to $DIR)"
      WARNINGS=$((WARNINGS + 1))
    fi
  done <<< "$IMAGES"
fi

# Summary
echo ""
if [[ "$ERRORS" -eq 0 ]] && [[ "$WARNINGS" -eq 0 ]]; then
  echo "OK: $SLIDE_COUNT slides, no issues found"
elif [[ "$ERRORS" -eq 0 ]]; then
  echo "OK with warnings: $SLIDE_COUNT slides, $WARNINGS warning(s)"
else
  echo "FAILED: $SLIDE_COUNT slides, $ERRORS error(s), $WARNINGS warning(s)"
  exit 1
fi
