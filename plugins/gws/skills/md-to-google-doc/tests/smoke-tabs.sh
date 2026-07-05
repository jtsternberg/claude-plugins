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

echo "== tab-update.sh publish into a tab =="
TAB2_ID=$(bash "$SCRIPTS/tabs.sh" add "$DOC_ID" "Publish Target")
cp "$SCRIPT_DIR/fixtures/tab-fixture.md" ./fixture.md
URL=$(bash "$SCRIPTS/tab-update.sh" ./fixture.md "$DOC_ID" --tab "Publish Target")
echo "$URL" | grep -q "tab=$TAB2_ID" || fail "unexpected URL: $URL"
pass "published fixture into $TAB2_ID"

echo "== verify tab content and isolation =="
gws docs documents get \
	--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true}" 2>/dev/null > verify.json
python3 - verify.json "$TAB2_ID" <<'PYEOF'
import json, sys

def text_of(content):
	out = []
	for e in content:
		if "paragraph" in e:
			for el in e["paragraph"].get("elements", []):
				out.append(el.get("textRun", {}).get("content", ""))
		elif "table" in e:
			for row in e["table"].get("tableRows", []):
				for cell in row.get("tableCells", []):
					out.append(text_of(cell.get("content", [])))
	return "".join(out)

d = json.load(open(sys.argv[1]))
tabs = {t["tabProperties"]["tabId"]: t for t in d["tabs"]}
assert len(tabs) == 2, "expected 2 tabs, got %d" % len(tabs)
target = text_of(tabs[sys.argv[2]]["documentTab"]["body"]["content"])
for needle in ("Fixture Heading", "bullet one", "nested bullet",
               "first", "a1", "b2", "Final paragraph"):
	assert needle in target, "missing %r in published tab" % needle
# heading style survived
paras = tabs[sys.argv[2]]["documentTab"]["body"]["content"]
h1 = [p for p in paras if p.get("paragraph", {})
      .get("paragraphStyle", {}).get("namedStyleType") == "HEADING_1"]
assert h1, "no HEADING_1 paragraph in published tab"
# a table exists
assert any("table" in p for p in paras), "no table in published tab"
# other tab untouched (still the empty default first tab)
first = [t for tid, t in tabs.items() if tid != sys.argv[2]][0]
assert text_of(first["documentTab"]["body"]["content"]).strip() == "", \
	"first tab was modified!"
print("PUBLISH VERIFY OK")
PYEOF
pass "tab content correct, sibling tab untouched"

echo "== re-publish (idempotent overwrite) =="
bash "$SCRIPTS/tab-update.sh" ./fixture.md "$DOC_ID" --tab "$TAB2_ID" >/dev/null
pass "re-publish into same tab succeeded"

echo "== guardrail: update.sh refuses multi-tab doc =="
printf '# nope\n' > nope.md
if bash "$SCRIPTS/update.sh" nope.md "$DOC_ID" 2>/dev/null; then
	fail "update.sh should have refused a 2-tab doc"
fi
pass "update.sh guardrail fired"

echo "ALL SMOKE CHECKS PASSED"
