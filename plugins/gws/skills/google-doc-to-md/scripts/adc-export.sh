#!/usr/bin/env bash
# Bash wrapper for adc_export.py — picks the right Python interpreter and
# execs the script. Prefers ~/.venvs/genai (macOS PEP 668 blocks pip installs
# into the system Python) and falls back to plain python3.
#
# Usage: adc-export.sh <doc-id-or-url> [output.md]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY="$HOME/.venvs/genai/bin/python3"
[[ -x "$PY" ]] || PY="python3"

exec "$PY" "$SCRIPT_DIR/adc_export.py" "$@"
