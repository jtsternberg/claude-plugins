#!/usr/bin/env bash
#
# bd-enumerate.sh — the one read-only beads enumeration path for this plugin.
#
# Runs `bd list` for a status set (or --all) and emits a bare JSON ARRAY of bead
# objects to stdout, normalized so callers never have to re-handle bd's
# list-or-wrapped shapes. This is the shared primitive behind BOTH
# collect-open-beads.sh (triage-beads) and tripwire-match.sh (tripwire-scan):
# neither forks its own `bd list --json`. Extracting it the moment the second
# caller appeared is the repo contract (CLAUDE.md § "Sharing Code Between Sibling
# Skills"; docs/compounding.md "Extract the helper the moment a second caller
# appears").
#
# Read-only: only `bd list` (a query). Never mutates beads state.
#
# Usage:
#   bd-enumerate.sh [--status <list> | --all] [--label <label>]
#
#   --status <list>  Comma-separated statuses. Default: open,in_progress,blocked
#   --all            Every issue regardless of status (for dependency status
#                    resolution). Mutually exclusive with --status.
#   --label <label>  Restrict to beads carrying this label.
#
# Exit codes:
#   0    success (array on stdout, possibly empty [])
#   1    `bd list` failed (its stderr is echoed)
#   127  `bd` not found on PATH

set -euo pipefail

STATUS="open,in_progress,blocked"
ALL=0
LABEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS="${2:?--status needs a value}"; shift 2 ;;
    --status=*) STATUS="${1#*=}"; shift ;;
    --all) ALL=1; shift ;;
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --label=*) LABEL="${1#*=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bd-enumerate.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! command -v bd >/dev/null 2>&1; then
  echo "bd-enumerate.sh: 'bd' (beads CLI) not found on PATH" >&2
  exit 127
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

list_args=(--json --limit 0)
if [ "$ALL" -eq 1 ]; then
  list_args+=(--all)
else
  list_args+=(--status "$STATUS")
fi
[ -n "$LABEL" ] && list_args+=(--label "$LABEL")

# Save raw to disk first: a parse failure then leaves the real response readable
# instead of a truncated pipe (docs/compounding.md "save the raw response to a
# file rather than piping straight into jq").
if ! bd list "${list_args[@]}" >"$tmp/raw.json" 2>"$tmp/raw.err"; then
  echo "bd-enumerate.sh: 'bd list ${list_args[*]}' failed:" >&2
  cat "$tmp/raw.err" >&2
  exit 1
fi

python3 - "$tmp/raw.json" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

# bd may return a bare list or an object wrapping issues under one of these keys.
if isinstance(data, list):
    beads = data
else:
    beads = []
    for key in ("issues", "items", "results"):
        if isinstance(data.get(key), list):
            beads = data[key]
            break

print(json.dumps(beads))
PY
