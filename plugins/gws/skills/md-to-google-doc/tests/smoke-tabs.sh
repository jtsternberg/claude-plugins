#!/usr/bin/env bash
# Live smoke test for tabs.sh (and later tab-update.sh).
# Creates a scratch Google Doc on the ACTIVE gws account, exercises the tab
# helpers, and trashes the doc at the end. Requires: gws auth login done.
# Usage: bash smoke-tabs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"

if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
	source "$SCRIPTS/../../../scripts/account-common.sh"
	export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
fi

WORK="$(mktemp -d /tmp/gws-tabs-smoke.XXXXXX)"
cd "$WORK"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "== creating scratch doc =="
DOC_ID=$(gws docs documents create --json '{"title": "TMP gws-tabs smoke (safe to delete)"}' 2>/dev/null \
	| python3 -c "import sys,json; print(json.load(sys.stdin)['documentId'])")
[[ -n "$DOC_ID" ]] || fail "could not create scratch doc"
trap 'gws drive files update --params "{\"fileId\": \"$DOC_ID\"}" --json "{\"trashed\": true}" >/dev/null 2>&1; rm -rf "$WORK"; echo "== scratch doc trashed =="' EXIT

echo "== tabs.sh add =="
TAB_ID=$(bash "$SCRIPTS/tabs.sh" add "$DOC_ID" "Next Steps" --emoji "⭐" --index 1)
[[ "$TAB_ID" == t.* ]] || fail "add did not return a tabId (got: $TAB_ID)"
pass "added tab $TAB_ID"

echo "== tabs.sh list =="
LIST=$(bash "$SCRIPTS/tabs.sh" list "$DOC_ID")
echo "$LIST" | grep -q "Next Steps" || fail "list missing new tab: $LIST"
[[ $(echo "$LIST" | wc -l) -eq 2 ]] || fail "expected 2 tabs, got: $LIST"
pass "list shows 2 tabs"

echo "== tabs.sh rename =="
bash "$SCRIPTS/tabs.sh" rename "$DOC_ID" "Next Steps" "Action Items" >/dev/null
bash "$SCRIPTS/tabs.sh" list "$DOC_ID" | grep -q "Action Items" || fail "rename did not apply"
pass "renamed to Action Items"

echo "== tabs.sh delete =="
bash "$SCRIPTS/tabs.sh" delete "$DOC_ID" "$TAB_ID" --yes >/dev/null
[[ $(bash "$SCRIPTS/tabs.sh" list "$DOC_ID" | wc -l) -eq 1 ]] || fail "delete did not remove tab"
pass "deleted tab"

echo "ALL TAB CRUD CHECKS PASSED"
