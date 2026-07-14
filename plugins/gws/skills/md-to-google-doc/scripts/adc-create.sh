#!/usr/bin/env bash
# Create (or update-in-place, via the state file) a Google Doc from markdown
# using gcloud ADC + the Drive/Docs APIs. Rung 2 of md-to-google-doc's
# source-routing plan — use when `gws` can't reach the target account.
#
# Usage: adc-create.sh <markdown-file> [folder-id-or-url] [--title "Title"] [--new]
#        adc-create.sh <markdown-file> --folder <folder-id-or-url> [--title "Title"] [--new]
# Output: Google Doc URL on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $(basename "$0") <markdown-file> [folder-id-or-url] [--title \"Title\"] [--new]" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage

FILE="$1"
shift

FOLDER_ID=""
TITLE=""
NEW_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder) FOLDER_ID="$2"; shift 2 ;;
    --title)  TITLE="$2"; shift 2 ;;
    --new)    NEW_FLAG="--new"; shift ;;
    --*)      echo "Unknown option: $1" >&2; usage ;;
    *)
      if [[ -z "$FOLDER_ID" ]]; then
        FOLDER_ID="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; usage
      fi
      ;;
  esac
done

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: File not found: $FILE" >&2
  exit 1
fi

# Preflight: fail fast with an actionable message if ADC isn't set up.
if ! bash "$SCRIPT_DIR/adc-check.sh" 2>/tmp/adc-check-err-$$; then
  cat /tmp/adc-check-err-$$ >&2
  rm -f /tmp/adc-check-err-$$
  exit 1
fi
rm -f /tmp/adc-check-err-$$

# Derive title if not provided (same logic as upload.sh: H1 heading, else filename).
if [[ -z "$TITLE" ]]; then
  TITLE=$(awk '
    BEGIN {skip=0}
    NR==1 && /^---$/ {skip=1; next}
    skip==1 && /^---$/ {skip=0; next}
    skip==0 && /^# / {sub(/^# /, ""); print; exit}
  ' "$FILE")
  if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$FILE" .md | tr '-' ' ')
  fi
fi

# Clean: strip YAML frontmatter and Obsidian callout headers.
CLEAN="./__tmp-adc-create-$$-$RANDOM.md"
: > "$CLEAN"
trap 'rm -f "$CLEAN"' EXIT
"$SCRIPT_DIR/clean.sh" "$FILE" "$CLEAN"

PY="$HOME/.venvs/genai/bin/python3"
[[ -x "$PY" ]] || PY="python3"

ARGS=("$CLEAN" --title "$TITLE" --source "$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")")
[[ -n "$FOLDER_ID" ]] && ARGS+=(--folder "$FOLDER_ID")
[[ -n "$NEW_FLAG" ]] && ARGS+=("$NEW_FLAG")

exec "$PY" "$SCRIPT_DIR/adc_create.py" "${ARGS[@]}"
