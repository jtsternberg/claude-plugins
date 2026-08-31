#!/usr/bin/env bash
#
# collect-open-beads.sh — build a deterministic triage worklist from beads.
#
# Emits one JSON object to stdout describing every non-frozen open bead, with
# each bead's dependencies already resolved to their CURRENT status. That
# dependency-closure fact ("has this bead's blocker closed since it was
# written?") is the one piece of reconciliation that is pure bookkeeping, so we
# compute it once here instead of making the triage agent re-derive it by hand
# for all N beads. Everything else — reading git, running tests, checking tool
# versions — is judgment the agent still has to do against reality.
#
# Read-only: this script only runs `bd list` (queries). It never mutates state.
#
# Usage:
#   collect-open-beads.sh [--status <list>] [--label <label>]
#
#   --status <list>  Comma-separated statuses to sweep.
#                    Default: open,in_progress,blocked
#                    (deferred and pinned are deliberately EXCLUDED — deferred
#                    is "on ice on purpose" and pinned is "stays open forever";
#                    triaging them fights the user's stated intent. Their count
#                    is reported separately as frozen_skipped.)
#   --label <label>  Only include beads carrying this label (optional scope).
#
# Output shape (see the skill's SKILL.md for how each field feeds triage):
#   {
#     "total_open": <int>,
#     "frozen_skipped": <int>,           # deferred+pinned, left untouched
#     "status_filter": "open,in_progress,blocked",
#     "label_filter": "<label or empty>",
#     "beads": [ { id, title, status, priority, type, parent, owner,
#                  created_at, updated_at, days_since_update, comment_count,
#                  description,
#                  deps: [ {id, type, status, closed} ],
#                  blocking_deps: <int>,
#                  blocking_deps_closed: <int>,
#                  all_blocking_deps_closed: <bool> } ]
#   }

set -euo pipefail

STATUS="open,in_progress,blocked"
LABEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS="${2:?--status needs a value}"; shift 2 ;;
    --status=*) STATUS="${1#*=}"; shift ;;
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --label=*) LABEL="${1#*=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "collect-open-beads.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# One shared enumeration path for the whole plugin: bd-enumerate.sh (at the
# plugin root) is the only place a `bd list` runs. tripwire-match.sh calls the
# same script — extracting it the moment the second caller appeared is the repo
# contract (CLAUDE.md § "Sharing Code Between Sibling Skills"). Resolve it from
# this script's own location, not a SKILL.md token: this is a script-to-sibling
# call, deterministic off $0.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENUMERATE="$SCRIPT_DIR/../../../scripts/bd-enumerate.sh"

# Pull the open worklist, every issue (for status resolution of deps), and the
# frozen count. Save each raw payload to a temp file first so a parse failure
# leaves the real output on disk to inspect, rather than a truncated pipe.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

enum_open=(--status "$STATUS")
[ -n "$LABEL" ] && enum_open+=(--label "$LABEL")

bash "$ENUMERATE" "${enum_open[@]}" >"$tmp/open.json" 2>"$tmp/open.err" || {
  rc=$?
  echo "collect-open-beads.sh: bead enumeration failed (rc=$rc):" >&2
  cat "$tmp/open.err" >&2
  exit "$rc"
}
bash "$ENUMERATE" --all >"$tmp/all.json" 2>/dev/null || echo '[]' >"$tmp/all.json"
bash "$ENUMERATE" --status deferred,pinned >"$tmp/frozen.json" 2>/dev/null || echo '[]' >"$tmp/frozen.json"

STATUS="$STATUS" LABEL="$LABEL" python3 - "$tmp/open.json" "$tmp/all.json" "$tmp/frozen.json" <<'PY'
import json, os, sys
from datetime import datetime, timezone

def load(path):
    with open(path) as fh:
        data = json.load(fh)
    # bd may return a bare list or an object wrapping "issues"/"items".
    if isinstance(data, list):
        return data
    for key in ("issues", "items", "results"):
        if isinstance(data.get(key), list):
            return data[key]
    return []

open_beads = load(sys.argv[1])
all_beads = load(sys.argv[2])
frozen = load(sys.argv[3])

status_by_id = {b.get("id"): b.get("status") for b in all_beads}

def days_since(ts):
    if not ts:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return (datetime.now(timezone.utc) - dt).days
        except ValueError:
            continue
    return None

out_beads = []
for b in open_beads:
    deps = []
    blocking = 0
    blocking_closed = 0
    for d in b.get("dependencies", []) or []:
        dep_id = d.get("depends_on_id")
        if dep_id == b.get("id"):
            # bd echoes the parent-child edge from the child's side; the
            # self-referential issue_id is not a real dependency to resolve.
            pass
        dep_status = status_by_id.get(dep_id, "unknown")
        dep_type = d.get("type", "")
        is_closed = dep_status == "closed"
        deps.append({
            "id": dep_id,
            "type": dep_type,
            "status": dep_status,
            "closed": is_closed,
        })
        # "blocks" edges are the ones that gate this bead. parent-child is
        # structure, not a blocker.
        if dep_type == "blocks":
            blocking += 1
            if is_closed:
                blocking_closed += 1

    out_beads.append({
        "id": b.get("id"),
        "title": b.get("title"),
        "status": b.get("status"),
        "priority": b.get("priority"),
        "type": b.get("issue_type"),
        "parent": b.get("parent"),
        "owner": b.get("owner"),
        "created_at": b.get("created_at"),
        "updated_at": b.get("updated_at"),
        "days_since_update": days_since(b.get("updated_at")),
        "comment_count": b.get("comment_count", 0),
        "description": b.get("description", ""),
        "deps": deps,
        "blocking_deps": blocking,
        "blocking_deps_closed": blocking_closed,
        "all_blocking_deps_closed": blocking > 0 and blocking == blocking_closed,
    })

# Sort by priority (0 highest) then most-stale-first so the agent triages the
# beads most likely to be actionable — and most annoying to JT — earliest.
out_beads.sort(key=lambda x: (
    x["priority"] if isinstance(x["priority"], int) else 99,
    -(x["days_since_update"] or 0),
))

print(json.dumps({
    "total_open": len(out_beads),
    "frozen_skipped": len(frozen),
    "status_filter": os.environ.get("STATUS", ""),
    "label_filter": os.environ.get("LABEL", ""),
    "beads": out_beads,
}, indent=2))
PY
